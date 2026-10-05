# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Protostar::Compiler's public surface: include path resolution, the bundled
# imports, the pool, diagnostics and the shape of what comes back
class CompilerFacadeTest < Minitest::Test
  C = Protostar::Compiler

  def with_dirs(*trees)
    Dir.mktmpdir do |root|
      dirs = trees.each_with_index.map do |tree, i|
        dir = File.join(root, "inc#{i}")
        tree.each do |name, body|
          path = File.join(dir, name)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, body)
        end
        FileUtils.mkdir_p(dir)
        dir
      end
      yield(*dirs)
    end
  end

  def test_include_paths_are_searched_in_order
    with_dirs({"x.proto" => "syntax = \"proto3\"; message First {}\n"},
      {"x.proto" => "syntax = \"proto3\"; message Second {}\n"}) do |a, b|
      file = C.new(include_paths: [a, b]).compile(["x.proto"]).last
      assert_equal ["First"], file.messages.map(&:name)
      file = C.new(include_paths: [b, a]).compile(["x.proto"]).last
      assert_equal ["Second"], file.messages.map(&:name)
    end
  end

  def test_bundled_includes_come_last
    with_dirs({"x.proto" => "syntax = \"proto3\"; import \"google/protobuf/timestamp.proto\";\n" \
                            "message X { google.protobuf.Timestamp at = 1; }\n"}) do |dir|
      files = C.new(include_paths: [dir]).compile(["x.proto"])
      assert_equal %w[google/protobuf/timestamp.proto x.proto], files.map(&:name)
      error = assert_raises(C::Error) { C.new(include_paths: [dir], bundled_includes: false).compile(["x.proto"]) }
      assert_equal ["google/protobuf/timestamp.proto: File not found.",
        "x.proto:1:20: Import \"google/protobuf/timestamp.proto\" was not found or had errors.",
        "x.proto:2:13: \"google.protobuf.Timestamp\" is not defined."], error.diagnostics.map(&:to_s)
    end
    with_dirs({"google/protobuf/empty.proto" => "syntax = \"proto3\"; package google.protobuf; message Empty { int32 own = 1; }\n"}) do |dir|
      empty = C.new(include_paths: [dir]).compile(["google/protobuf/empty.proto"]).last
      assert_equal ["own"], empty.find_message("google.protobuf.Empty").fields.map(&:name)
    end
  end

  def test_every_bundled_include_compiles
    names = Dir[File.join(C::INCLUDE_DIR, "**", "*.proto")].map { |p| p.delete_prefix(C::INCLUDE_DIR + "/") }.sort
    assert_equal %w[google/protobuf/any.proto google/protobuf/api.proto google/protobuf/compiler/plugin.proto
      google/protobuf/cpp_features.proto google/protobuf/descriptor.proto google/protobuf/duration.proto
      google/protobuf/empty.proto google/protobuf/field_mask.proto google/protobuf/java_features.proto
      google/protobuf/source_context.proto google/protobuf/struct.proto google/protobuf/timestamp.proto
      google/protobuf/type.proto google/protobuf/wrappers.proto], names
    compiler = C.new
    files = compiler.compile(names)
    assert_equal names.sort, files.map(&:name).sort
    assert File.exist?(File.join(C::INCLUDE_DIR, "LICENSE"))
  end

  def test_imports_compile_first_and_once_and_the_pool_reuses_them
    sources = {
      "a.proto" => "syntax = \"proto3\"; message A {}\n",
      "b.proto" => "syntax = \"proto3\"; import \"a.proto\"; message B { A a = 1; }\n",
      "c.proto" => "syntax = \"proto3\"; import \"a.proto\"; import \"b.proto\"; message C { A a = 1; B b = 2; }\n"
    }
    pool = Protostar::Schema::Pool.new
    compiler = C.new(pool: pool)
    files = compiler.compile(["c.proto"], sources: sources, retain_options: true)
    assert_equal %w[a.proto b.proto c.proto], files.map(&:name)
    assert_equal %w[a.proto b.proto c.proto], pool.files.map(&:name)
    assert_same pool.file("a.proto"), files.first

    again = compiler.compile(["b.proto", "c.proto"], sources: {}, retain_options: true)
    assert_equal %w[a.proto b.proto c.proto], again.map(&:name)
    assert_same files.last, again.last
    assert_same compiler.compile(["c.proto"]).last, compiler.compile(["c.proto"]).last
  end

  def test_compile_to_hashes
    hashes = C.new.compile_to_hashes(["x.proto"], sources: {"x.proto" => "syntax = \"proto3\"; message X { int32 a_b = 1; }\n"})
    assert_equal [{name: "x.proto", message_type: [{name: "X", field: [{name: "a_b", number: 1, label: :LABEL_OPTIONAL,
                                                                        type: :TYPE_INT32, json_name: "aB"}]}], syntax: "proto3"}], hashes
  end

  def test_source_info_on_request
    sources = {"x.proto" => "// leading\nsyntax = \"proto3\";\nmessage X {}\n"}
    assert_nil C.new.compile(["x.proto"], sources: sources).last.source_info
    info = C.new.compile(["x.proto"], sources: sources, source_info: true).last.source_info
    assert_equal [1, 0, 2, 12], info.location([]).span
    assert_equal " leading\n", info.location([12]).leading_comments
  end

  def test_source_retention_options_are_stripped_unless_retained
    sources = {"x.proto" => "edition = \"2024\";\noption features.enforce_naming_style = STYLE_LEGACY;\nmessage x {}\n"}
    stripped = C.new.compile(["x.proto"], sources: sources).last
    assert_equal({features: {}}, stripped.to_h[:options])
    retained = C.new.compile(["x.proto"], sources: sources, retain_options: true).last
    assert_equal({features: {enforce_naming_style: :STYLE_LEGACY}}, retained.to_h[:options])
    assert_equal :STYLE_LEGACY, retained.features.enforce_naming_style
  end

  def test_errors_list_every_diagnostic
    error = assert_raises(C::Error) do
      C.new.compile(["x.proto"], sources: {"x.proto" => "syntax = \"proto3\";\nmessage X {\n  A a = 1;\n  B b = 2;\n}\n"})
    end
    assert_equal "x.proto:3:3: \"A\" is not defined.\nx.proto:4:3: \"B\" is not defined.", error.message
    assert_kind_of Protostar::Error, error
  end

  def test_warnings_are_kept_on_success
    compiler = C.new
    compiler.compile(["x.proto"], sources: {
      "x.proto" => "syntax = \"proto3\";\nimport \"y.proto\";\nmessage X {}\n",
      "y.proto" => "syntax = \"proto3\";\nmessage Y {}\n"
    })
    warning = compiler.diagnostics.first
    assert warning.warning?
    assert_equal "x.proto:2:1: warning: Import y.proto is unused.", warning.to_s
  end

  def test_unused_imports_are_reported_for_named_files_only
    sources = {
      "x.proto" => "syntax = \"proto3\";\nimport \"y.proto\";\nmessage X { Y y = 1; }\n",
      "y.proto" => "syntax = \"proto3\";\nimport \"z.proto\";\nmessage Y {}\n",
      "z.proto" => "syntax = \"proto3\";\nmessage Z {}\n"
    }
    compiler = C.new
    compiler.compile(["x.proto"], sources: sources)
    assert_empty compiler.diagnostics
  end

  def test_missing_file
    error = assert_raises(C::Error) { C.new.compile(["nope.proto"]) }
    assert_equal "nope.proto: File not found.", error.message
    assert_nil error.diagnostics.first.line
  end

  def test_results_are_frozen_and_shareable
    files = C.new.compile(["google/protobuf/descriptor.proto"], source_info: true)
    assert files.all? { |f| Ractor.shareable?(f) }
  end

  def test_compiled_descriptor_proto_matches_its_golden
    file = C.new.compile(["google/protobuf/descriptor.proto"]).last
    expected = GoldenHash.load(Corpus.golden("google/protobuf/descriptor.proto", :json)).last
    assert_equal expected, file.to_proto.to_h
  end
end
