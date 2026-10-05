# frozen_string_literal: true

require "test_helper"
require "json"

# The inline cases of protoc's parser_unittest.cc, extracted by
# script/extract_parser_cases.rb. Parse cases compare the parser's
# FileDescriptorProto (names unresolved, options uninterpreted) and its
# 0-based `line:column: message` errors; validation cases build the parsed
# file in a bare pool, as the C++ test does with its own DescriptorPool.
class CompilerParserCasesTest < Minitest::Test
  DATA = JSON.parse(File.read(File.expand_path("../corpus/parser_cases/cases.json", __dir__)))

  # The files these C++ tests build into their pool before the case
  SETUPS = {
    "ParserValidationErrorTest.PackageNameError" => [{name: "bar.proto", message_type: [{name: "foo"}]}],
    "ParserValidationErrorTest.ImportTwice" => [{name: "bar.proto", message_type: [{name: "foo"}]}],
    "ParserValidationErrorTest.ImportOptionTwice" => [
      :descriptor,
      {name: "bar.proto", dependency: ["google/protobuf/descriptor.proto"],
       extension: [{name: "ext", number: 5000, type: :TYPE_INT64, extendee: "google.protobuf.FieldOptions"}]}
    ],
    "ParserValidationErrorTest.ImportAndImportOptionTwice" => [
      :descriptor,
      {name: "bar.proto", dependency: ["google/protobuf/descriptor.proto"], message_type: [{name: "foo"}],
       extension: [{name: "ext", number: 5000, type: :TYPE_INT64, extendee: "google.protobuf.FieldOptions"}]}
    ],
    "ParserValidationErrorTest.DuplicateFileError" => [{name: "foo.proto"}],
    "ParserValidationErrorTest.ResolvedUndefinedError" => [{name: "base.proto", package: "base", message_type: [{name: "bar"}]}],
    "ParserValidationErrorTest.ResolvedUndefinedOptionError" => [
      :descriptor,
      {name: "base2.proto", package: "baz", dependency: ["google/protobuf/descriptor.proto"],
       message_type: [{name: "Bar", field: [{name: "foo", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32}]}],
       extension: [{name: "bar", number: 7672757, label: :LABEL_OPTIONAL, type: :TYPE_MESSAGE, type_name: "Bar",
                    extendee: "google.protobuf.FileOptions"}]}
    ]
  }.freeze

  # Errors accumulate over the calls of one C++ test, as its collector does
  def self.accumulated
    @accumulated ||= begin
      text = Hash.new { |h, k| h[k] = +"" }
      DATA["cases"].to_h do |c|
        text[c["test"]] = +"" if c["fresh"]
        parser = Protostar::Compiler::Parser.new(c["input"], require_syntax: c["require_syntax"])
        parser.parse
        text[c["test"]] << parser.errors.map { |l, col, m| "#{l}:#{col}: #{m}\n" }.join
        [c["id"], text[c["test"]].dup]
      end
    end
  end

  DATA["cases"].each do |c|
    define_method(:"test_#{c["id"].tr(".#", "__")}") do
      run_case(c)
    end
  end

  def test_extraction_covers_the_file
    assert_operator DATA["cases"].size, :>=, 239
    skipped = DATA["skipped"].map { |s| s["id"] }
    assert_equal 5, skipped.size, "cases with computed inputs, covered by hand below: #{skipped}"
  end

  # IgnoreBOM and BOMError
  def test_utf8_byte_order_mark
    input = "\xEF\xBB\xBF message TestMessage {\n  required int32 foo = 1;\n}\n".b
    parser = Protostar::Compiler::Parser.new(input)
    ast = parser.parse
    assert_empty parser.errors
    assert_equal "foo", ast.message_type[0].field[0].name
    bad = Protostar::Compiler::Parser.new("\xEF   message TestMessage {\n  required int32 foo = 1;\n}\n".b)
    bad.parse
    assert_equal [[0, 1, "Proto file starts with 0xEF but not UTF-8 BOM. Only UTF-8 is accepted for proto file."],
      [0, 0, "Expected top-level statement (e.g. \"message\")."]], bad.errors
  end

  # NestingIsLimitedWithoutCrashing
  def test_nesting_is_limited
    deep = ->(n) { "syntax = \"proto2\";\n" + ("message M {" * n) + ("}" * n) }
    ok = Protostar::Compiler::Parser.new(deep.call(31))
    ok.parse
    assert_empty ok.errors
    compiler = Protostar::Compiler.new(bundled_includes: false)
    compiler.compile(["foo.proto"], sources: {"foo.proto" => deep.call(31)}, protoc_cli: false)
    too_deep = Protostar::Compiler::Parser.new(deep.call(32))
    too_deep.parse
    assert(too_deep.errors.any? { |_, _, m| m == "Reached maximum recursion limit for nested messages." })
    huge = Protostar::Compiler::Parser.new(deep.call(5_000))
    huge.parse
    assert(huge.errors.any? { |_, _, m| m == "Reached maximum recursion limit for nested messages." })
  end

  # RegressionNestedOpenBraceDoNotStackOverflow
  def test_nested_open_braces
    parser = Protostar::Compiler::Parser.new("edition=\"a\0;".b + ("{" * 100_000))
    parser.parse
    assert_equal [[0, 10, "Unexpected end of string."], [0, 10, "Invalid control characters encountered in text."],
      [0, 8, "Unknown edition \"a\"."]], parser.errors
  end

  private

  def run_case(c)
    case c["kind"]
    when "ExpectParsesTo"
      parser = Protostar::Compiler::Parser.new(c["input"], require_syntax: c["require_syntax"])
      ast = parser.parse
      assert_empty parser.errors
      assert_equal :end, parser.current_token.type
      assert_equal GoldenHash.convert(c["expected"], "google.protobuf.FileDescriptorProto"), ast.to_h
    when "ExpectHasErrors", "ExpectHasEarlyExitErrors"
      parser = Protostar::Compiler::Parser.new(c["input"], require_syntax: c["require_syntax"])
      parser.parse
      assert_equal :end, parser.current_token.type if c["kind"] == "ExpectHasErrors"
      assert_errors c, self.class.accumulated.fetch(c["id"])
    when "ExpectHasWarnings"
      parser = Protostar::Compiler::Parser.new(c["input"], require_syntax: c["require_syntax"])
      parser.parse
      assert_empty parser.errors
      assert_equal c["expected"], parser.warnings.map { |l, col, m| "#{l}:#{col}: #{m}\n" }.join
    when "ExpectHasValidationErrors"
      pool = Protostar::Schema::Pool.new
      setup_pool(c, pool)
      compiler = Protostar::Compiler.new(pool: pool, bundled_includes: false)
      diagnostics = begin
        compiler.compile(["foo.proto"], sources: {"foo.proto" => c["input"]}, protoc_cli: false)
        flunk "expected validation errors"
      rescue Protostar::Compiler::Error => e
        e.diagnostics
      end
      assert_errors c, CompilerSupport.zero_based(diagnostics.select(&:error?))
    else
      flunk "unknown case kind #{c["kind"]}"
    end
  end

  def assert_errors(c, actual)
    if c["substring"]
      assert_includes actual, c["expected"]
    else
      assert_equal c["expected"], actual
    end
  end

  def setup_pool(c, pool)
    files = SETUPS[c["id"]]
    assert files, "#{c["id"]} builds files into its pool; add them to SETUPS" if c["setup"]
    Array(files).each do |hash|
      if hash == :descriptor
        Protostar::Compiler.new(pool: pool).compile(["google/protobuf/descriptor.proto"])
      else
        pool.add(Protostar::Schema::Builder.build(hash, pool: pool))
      end
    end
  end
end
