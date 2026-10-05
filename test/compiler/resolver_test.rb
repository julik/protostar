# frozen_string_literal: true

require "test_helper"

# The compiler's linker resolves names with its own symbol table, which
# follows protoc's DescriptorBuilder::LookupSymbol (it must see the file
# being compiled before any descriptor exists, and give protoc's errors).
# These are the cases of test/schema/resolver_test.rb written as .proto
# source: the compiler resolves each the same way, and Schema::Resolver,
# run over the built file, agrees.
class CompilerResolverTest < Minitest::Test
  S = Protostar::Schema

  def compile(files)
    compiler = Protostar::Compiler.new
    built = compiler.compile([files.keys.last], sources: files)
    [compiler, built.last]
  end

  def compile_error(files)
    error = assert_raises(Protostar::Compiler::Error) { compile(files) }
    error.diagnostics.map(&:message)
  end

  # Asserts the compiler resolved `field`'s type to `expected` and that
  # Schema::Resolver resolves the written name to the same descriptor
  def assert_resolves(file, field_full_name, written, expected)
    field = file.find_symbol(field_full_name)
    assert_equal expected, field.type_name
    scope = field.containing_message.full_name
    assert_same field.message_type || field.enum_type, S::Resolver.resolve(written, scope: scope, file: file)
  end

  def test_searches_the_innermost_scope_first
    _, file = compile("foo.proto" => "syntax = \"proto2\"; package pkg;\nmessage Inner {}\n" \
      "message Outer { message Inner {} optional Inner inner = 1; }\n")
    assert_resolves file, "pkg.Outer.inner", "Inner", "pkg.Outer.Inner"
  end

  def test_walks_outward_through_enclosing_scopes_and_packages
    _, file = compile(
      "base.proto" => "syntax = \"proto2\"; package a.b; message Shared {}\n",
      "foo.proto" => "syntax = \"proto2\"; package a.b.c; import \"base.proto\";\n" \
        "message M { message N { optional Shared x = 1; optional b.Shared y = 2; } }\n"
    )
    assert_resolves file, "a.b.c.M.N.x", "Shared", "a.b.Shared"
    assert_resolves file, "a.b.c.M.N.y", "b.Shared", "a.b.Shared"
  end

  def test_leading_dot_is_fully_qualified
    _, file = compile("foo.proto" => "syntax = \"proto2\"; package pkg;\nmessage Bar {}\n" \
      "message Foo { message Bar {} optional .pkg.Bar bar = 1; }\n")
    assert_resolves file, "pkg.Foo.bar", ".pkg.Bar", "pkg.Bar"
  end

  def test_compound_name_does_not_search_further_out_once_the_first_part_is_found
    messages = compile_error("foo.proto" => "syntax = \"proto2\";\nmessage Bar { message Baz {} }\n" \
      "message Foo { message Bar {} optional Bar.Baz baz = 1; }\n")
    assert_equal ["\"Bar.Baz\" is resolved to \"Foo.Bar.Baz\", which is not defined. The innermost scope is " \
      "searched first in name resolution. Consider using a leading '.'(i.e., \".Bar.Baz\") to start from the " \
      "outermost scope."], messages
    error = assert_raises(S::ResolveError) do
      SchemaFixtures.from_proto({name: "x.proto", message_type: [{name: "Bar", nested_type: [{name: "Baz"}]},
        {name: "Foo", nested_type: [{name: "Bar"}], field: [{name: "baz", number: 1, type_name: "Bar.Baz"}]}]},
        S::Pool.new)
    end
    assert_includes error.message, "\"Bar.Baz\" is resolved to \"Foo.Bar.Baz\""
  end

  def test_first_part_that_cannot_contain_names_is_skipped
    _, file = compile("foo.proto" => "syntax = \"proto2\";\nmessage Bar { message Baz {} }\n" \
      "message Foo { optional bytes Bar = 1; optional Bar.Baz baz = 2; }\n")
    assert_resolves file, "Foo.baz", "Bar.Baz", "Bar.Baz"
  end

  def test_simple_name_skips_things_that_are_not_types
    _, file = compile("foo.proto" => "syntax = \"proto2\";\nmessage Bar {}\nmessage Foo { optional Bar Bar = 1; }\n")
    assert_resolves file, "Foo.Bar", "Bar", "Bar"
  end

  def test_qualified_name_of_a_field_is_not_a_type
    assert_equal ["\".Foo.bar\" is not a type."],
      compile_error("foo.proto" => "syntax = \"proto2\";\nmessage Foo { optional .Foo.bar foo = 1; optional int32 bar = 2; }\n")
  end

  def test_relative_name_of_a_field_is_not_a_type
    assert_equal ["\"Bar.Baz\" is not a type."], compile_error("foo.proto" => "syntax = \"proto2\";\n" \
      "message Foo { message Bar { optional int32 Baz = 2; } optional Bar.Baz foo = 1; }\n")
  end

  def test_package_is_visible_through_any_import_declaring_it
    _, file = compile(
      "foo.proto" => "syntax = \"proto2\"; package foo.bar;\n",
      "bar.proto" => "syntax = \"proto2\"; package foo.bar; import \"foo.proto\"; message Bar {}\n",
      "baz.proto" => "syntax = \"proto2\"; package foo; import \"bar.proto\"; message Baz { optional bar.Bar moo = 1; }\n"
    )
    assert_resolves file, "foo.Baz.moo", "bar.Bar", "foo.bar.Bar"
  end

  def test_symbols_of_files_not_imported_are_invisible
    compiler = Protostar::Compiler.new
    compiler.compile(["other.proto"], sources: {"other.proto" => "syntax = \"proto2\"; package pkg; message Hidden {}\n"})
    error = assert_raises(Protostar::Compiler::Error) do
      compiler.compile(["foo.proto"], sources: {"foo.proto" =>
        "syntax = \"proto2\"; package pkg; message Foo { optional Hidden h = 1; }\n"})
    end
    assert_equal ["\"pkg.Hidden\" seems to be defined in \"other.proto\", which is not imported by \"foo.proto\".  To " \
      "use it here, please add the necessary import."], error.diagnostics.map(&:message)
  end

  def test_public_imports_are_visible_transitively_and_plain_ones_are_not
    files = {
      "deep.proto" => "syntax = \"proto2\"; package d; message Deep {}\n",
      "middle_public.proto" => "syntax = \"proto2\"; import public \"deep.proto\";\n",
      "top_public.proto" => "syntax = \"proto2\"; import public \"middle_public.proto\";\n",
      "middle_private.proto" => "syntax = \"proto2\"; import \"deep.proto\";\n",
      "a.proto" => "syntax = \"proto2\"; import \"top_public.proto\"; message A { optional .d.Deep d = 1; }\n"
    }
    _, file = compile(files)
    assert_equal "d.Deep", file.find_message("A").field("d").type_name
    assert_equal %w[a.proto top_public.proto middle_public.proto deep.proto], file.visible_files.map(&:name)

    messages = compile_error(files.merge("b.proto" =>
      "syntax = \"proto2\"; import \"middle_private.proto\"; message B { optional .d.Deep d = 1; }\n"))
    assert_equal ["\"d.Deep\" seems to be defined in \"deep.proto\", which is not imported by \"b.proto\".  To use " \
      "it here, please add the necessary import."], messages
  end

  def test_undefined_extendee_and_method_types
    assert_equal ["\"Nope\" is not defined."],
      compile_error("e.proto" => "syntax = \"proto2\"; extend Nope { optional int32 x = 1; }\n")
    assert_equal ["\"Nope\" is not defined.", "\"Nope\" is not defined."],
      compile_error("s.proto" => "syntax = \"proto3\"; service S { rpc M(Nope) returns (Nope); }\n")
  end

  def test_method_types_resolve_from_the_service_scope
    _, file = compile("s.proto" => "syntax = \"proto3\"; package pkg; message Req {}\n" \
      "service S { rpc M(Req) returns (.pkg.Req); }\n")
    method = file.services.first.rpc(:M)
    assert_same file.find_message("pkg.Req"), method.input_type
    assert_same method.input_type, method.output_type
    assert_same method.input_type, S::Resolver.resolve("Req", scope: "pkg.S", file: file)
  end

  def test_enum_values_resolve_in_the_enclosing_scope
    _, file = compile("foo.proto" => "syntax = \"proto2\"; package pkg;\nenum Color { RED = 0; }\n" \
      "message Foo { optional Color c = 1 [default = RED]; }\n")
    assert_equal :RED, file.find_message("pkg.Foo").field("c").default_value
    assert_equal "pkg.RED", S::Resolver.resolve("RED", scope: "pkg.Foo", file: file, types_only: false).full_name
  end
end
