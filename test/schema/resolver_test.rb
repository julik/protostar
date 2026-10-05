# frozen_string_literal: true

require "test_helper"

# Scoping rules from the `type_name` comment in descriptor.proto and the
# lookup cases in descriptor_unittest.cc
class ResolverTest < Minitest::Test
  S = Protostar::Schema

  def setup
    @pool = S::Pool.new
  end

  def add(hash)
    SchemaFixtures.add(@pool, hash)
  end

  def field(name, number, type_name)
    {name: name, number: number, label: :LABEL_OPTIONAL, type_name: type_name}
  end

  def test_searches_the_innermost_scope_first
    file = add(name: "foo.proto", package: "pkg", message_type: [
      {name: "Inner"},
      {name: "Outer", nested_type: [{name: "Inner"}], field: [field("inner", 1, "Inner")]}
    ])
    assert_equal "pkg.Outer.Inner", file.find_message("pkg.Outer").field("inner").type_name
  end

  def test_walks_outward_through_enclosing_scopes_and_packages
    add(name: "base.proto", package: "a.b", message_type: [{name: "Shared"}])
    file = add(name: "foo.proto", package: "a.b.c", dependency: ["base.proto"], message_type: [
      {name: "M", nested_type: [{name: "N", field: [field("x", 1, "Shared"), field("y", 2, "b.Shared")]}]}
    ])
    n = file.find_message("a.b.c.M.N")
    assert_equal "a.b.Shared", n.field("x").type_name
    assert_equal "a.b.Shared", n.field("y").type_name
  end

  def test_leading_dot_is_fully_qualified
    file = add(name: "foo.proto", package: "pkg", message_type: [
      {name: "Bar"},
      {name: "Foo", nested_type: [{name: "Bar"}], field: [field("bar", 1, ".pkg.Bar")]}
    ])
    assert_equal "pkg.Bar", file.find_message("pkg.Foo").field("bar").type_name
  end

  # SearchMostLocalFirst
  def test_compound_name_does_not_search_further_out_once_the_first_part_is_found
    error = assert_raises(S::ResolveError) do
      add(name: "foo.proto", message_type: [
        {name: "Bar", nested_type: [{name: "Baz"}]},
        {name: "Foo", nested_type: [{name: "Bar"}], field: [field("baz", 1, "Bar.Baz")]}
      ])
    end
    assert_includes error.message, "\"Bar.Baz\" is resolved to \"Foo.Bar.Baz\", which is not defined"
    assert_equal "Bar.Baz", error.name
    assert_equal "Foo", error.scope
  end

  # SearchMostLocalFirst2
  def test_first_part_that_cannot_contain_names_is_skipped
    file = add(name: "foo.proto", message_type: [
      {name: "Bar", nested_type: [{name: "Baz"}]},
      {name: "Foo", field: [{name: "Bar", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_BYTES},
        field("baz", 2, "Bar.Baz")]}
    ])
    assert_equal "Bar.Baz", file.find_message("Foo").field("baz").type_name
  end

  # FieldTypeMayBeItsName
  def test_simple_name_skips_things_that_are_not_types
    file = add(name: "foo.proto", message_type: [
      {name: "Bar"},
      {name: "Foo", field: [field("Bar", 1, "Bar")]}
    ])
    assert_equal "Bar", file.find_message("Foo").field("Bar").type_name
  end

  # FieldTypeNotAType
  def test_qualified_name_of_a_field_is_not_a_type
    error = assert_raises(S::ResolveError) do
      add(name: "foo.proto", message_type: [{name: "Foo", field: [
        field("foo", 1, ".Foo.bar"),
        {name: "bar", number: 2, label: :LABEL_OPTIONAL, type: :TYPE_INT32}
      ]}])
    end
    assert_includes error.message, "\".Foo.bar\" is not a type"
  end

  # RelativeFieldTypeNotAType
  def test_relative_name_of_a_field_is_not_a_type
    error = assert_raises(S::ResolveError) do
      add(name: "foo.proto", message_type: [{
        name: "Foo",
        nested_type: [{name: "Bar", field: [{name: "Baz", number: 2, label: :LABEL_OPTIONAL, type: :TYPE_INT32}]}],
        field: [field("foo", 1, "Bar.Baz")]
      }])
    end
    assert_includes error.message, "\"Bar.Baz\" is not a type"
  end

  # PackageOriginallyDeclaredInTransitiveDependent
  def test_package_is_visible_through_any_import_declaring_it
    add(name: "foo.proto", package: "foo.bar")
    add(name: "bar.proto", package: "foo.bar", dependency: ["foo.proto"], message_type: [{name: "Bar"}])
    file = add(name: "baz.proto", package: "foo", dependency: ["bar.proto"], message_type: [
      {name: "Baz", field: [field("moo", 1, "bar.Bar")]}
    ])
    assert_equal "foo.bar.Bar", file.find_message("foo.Baz").field("moo").type_name
  end

  def test_symbols_of_files_not_imported_are_invisible
    add(name: "other.proto", package: "pkg", message_type: [{name: "Hidden"}])
    error = assert_raises(S::ResolveError) do
      add(name: "foo.proto", package: "pkg", message_type: [{name: "Foo", field: [field("h", 1, "Hidden")]}])
    end
    assert_includes error.message, "\"pkg.Hidden\" seems to be defined in \"other.proto\", which is not imported"
  end

  def test_public_imports_are_visible_transitively_and_plain_ones_are_not
    add(name: "deep.proto", package: "d", message_type: [{name: "Deep"}])
    add(name: "middle_public.proto", dependency: ["deep.proto"], public_dependency: [0])
    add(name: "top_public.proto", dependency: ["middle_public.proto"], public_dependency: [0])
    add(name: "middle_private.proto", dependency: ["deep.proto"])

    seen = add(name: "a.proto", dependency: ["top_public.proto"], message_type: [{name: "A", field: [field("d", 1, ".d.Deep")]}])
    assert_equal "d.Deep", seen.find_message("A").field("d").type_name
    assert_equal %w[a.proto top_public.proto middle_public.proto deep.proto], seen.visible_files.map(&:name)

    assert_raises(S::ResolveError) do
      add(name: "b.proto", dependency: ["middle_private.proto"], message_type: [{name: "B", field: [field("d", 1, ".d.Deep")]}])
    end
  end

  def test_undefined_name
    error = assert_raises(S::ResolveError) do
      add(name: "foo.proto", package: "pkg", message_type: [{name: "Foo", field: [field("x", 1, "Nope")]}])
    end
    assert_includes error.message, "\"Nope\" is not defined"
    assert_includes error.message, "pkg.Foo.x"
    assert_equal "pkg.Foo", error.scope
  end

  def test_undefined_extendee_and_method_types
    assert_raises(S::ResolveError) do
      add(name: "e.proto", extension: [{name: "x", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32, extendee: "Nope"}])
    end
    assert_raises(S::ResolveError) do
      add(name: "s.proto", service: [{name: "S", method: [{name: "M", input_type: "Nope", output_type: "Nope"}]}])
    end
  end

  def test_method_types_resolve_from_the_service_scope
    file = add(name: "s.proto", package: "pkg", message_type: [{name: "Req"}],
      service: [{name: "S", method: [{name: "M", input_type: "Req", output_type: ".pkg.Req"}]}])
    method = file.services.first.method(:M)
    assert_same file.find_message("pkg.Req"), method.input_type
    assert_same method.input_type, method.output_type
  end

  def test_direct_api
    file = add(name: "foo.proto", package: "pkg", enum_type: [{name: "Color", value: [{name: "RED", number: 0}]}],
      message_type: [{name: "Foo", field: [{name: "Color", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32}]}])
    enum = file.find_enum("pkg.Color")
    assert_same enum, S::Resolver.resolve("Color", scope: "pkg.Foo", file: file, pool: @pool)
    field = S::Resolver.resolve("Color", scope: "pkg.Foo", file: file, pool: @pool, types_only: false)
    assert_equal "pkg.Foo.Color", field.full_name
    assert_equal "pkg.RED", S::Resolver.resolve("RED", scope: "pkg.Foo", file: file, types_only: false).full_name
    assert_raises(S::ResolveError) { S::Resolver.resolve("", scope: "", file: file) }
  end

  def test_type_name_without_type_is_inferred
    file = add(name: "foo.proto", message_type: [{name: "M"}], enum_type: [{name: "E", value: [{name: "Z", number: 0}]}])
    other = add(name: "bar.proto", dependency: ["foo.proto"], message_type: [{name: "N", field: [field("m", 1, "M"), field("e", 2, "E")]}])
    n = other.find_message("N")
    assert_equal :message, n.field("m").type
    assert_equal :TYPE_MESSAGE, n.field("m").to_h[:type]
    assert_equal :enum, n.field("e").type
    assert_equal ".M", n.field("m").to_h[:type_name]
    assert_same file.find_message("M"), n.field("m").message_type
  end

  def test_declared_type_must_match_what_resolves
    assert_raises(S::ResolveError) do
      add(name: "foo.proto", message_type: [{name: "M", field: [
        {name: "m", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_ENUM, type_name: "M"}
      ]}])
    end
  end
end
