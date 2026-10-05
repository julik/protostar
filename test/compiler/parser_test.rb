# frozen_string_literal: true

require "test_helper"

# The parser's tree and source locations, beyond what the extracted
# parser_unittest.cc cases cover
class CompilerParserTest < Minitest::Test
  P = Protostar::Compiler::Parser

  def parse(text)
    parser = P.new(text)
    ast = parser.parse("t.proto")
    assert_empty parser.errors
    ast
  end

  def location(ast, path)
    ast.locations.find { |l| l.path == path }
  end

  # The example in the SourceCodeInfo comment of descriptor.proto
  def test_comment_attachment_as_documented_in_descriptor_proto
    ast = parse(<<~PROTO)
      syntax = "proto2";
      message M {
        optional int32 foo = 1;  // Comment attached to foo.
        // Comment attached to bar.
        optional int32 bar = 2;

        optional string baz = 3;
        // Comment attached to baz.
        // Another line attached to baz.

        // Comment attached to moo.
        //
        // Another line attached to moo.
        optional double moo = 4;

        // Detached comment for corge. This is not leading or trailing comments
        // to moo or corge because there are blank lines separating it from
        // both.

        // Detached comment for corge paragraph 2.

        optional string corge = 5;
        /* Block comment attached
         * to corge.  Leading asterisks
         * will be removed. */
        /* Block comment attached to
         * grault. */
        optional int32 grault = 6;

        // ignored detached comments.
      }
    PROTO
    field = ->(i) { location(ast, [4, 0, 2, i]) }
    assert_equal " Comment attached to foo.\n", field.call(0).trailing_comments
    assert_equal " Comment attached to bar.\n", field.call(1).leading_comments
    assert_equal " Comment attached to baz.\n Another line attached to baz.\n", field.call(2).trailing_comments
    assert_equal " Comment attached to moo.\n\n Another line attached to moo.\n", field.call(3).leading_comments
    assert_equal [" Detached comment for corge. This is not leading or trailing comments\n to moo or corge because " \
      "there are blank lines separating it from\n both.\n", " Detached comment for corge paragraph 2.\n"],
      field.call(4).leading_detached_comments
    assert_equal " Block comment attached\n to corge.  Leading asterisks\n will be removed. ", field.call(4).trailing_comments
    assert_equal " Block comment attached to\n grault. ", field.call(5).leading_comments
    assert_nil field.call(5).trailing_comments
  end

  def test_spans_omit_the_end_line_when_on_one_line
    ast = parse("syntax = \"proto3\";\nmessage A {\n  int32 x = 1;\n}\n")
    assert_equal [0, 0, 3, 1], location(ast, []).span
    assert_equal [1, 0, 3, 1], location(ast, [4, 0]).span
    assert_equal [2, 2, 14], location(ast, [4, 0, 2, 0]).span
    assert_equal [2, 8, 9], location(ast, [4, 0, 2, 0, 1]).span
    assert_equal [2, 2, 7], location(ast, [4, 0, 2, 0, 5]).span
  end

  def test_positions_for_diagnostics
    ast = parse("syntax = \"proto2\";\npackage p;\nmessage A {\n  optional Foo x = 1 [default = BAR];\n}\n")
    field = ast.message_type[0].field[0]
    assert_equal [3, 11], field.position(:type)
    assert_equal [3, 15], field.position(:name)
    assert_equal [3, 19], field.position(:number)
    assert_equal [3, 32], field.position(:default_value)
    assert_equal [2, 8], ast.message_type[0].position(:name)
    assert_equal [1, 0], ast.position(:name)
    assert_equal [0, 0], ast.position(:editions)
  end

  def test_map_fields_expand_to_entry_messages
    ast = parse("syntax = \"proto3\";\nmessage A {\n  map<string, A> my_map = 1 [features.utf8_validation = NONE];\n}\n")
    message = AstHash.file(ast)[:message_type][0]
    assert_equal({name: "my_map", number: 1, label: :LABEL_REPEATED, type_name: "MyMapEntry",
      options: {uninterpreted_option: [{name: [{name_part: "features", is_extension: false},
        {name_part: "utf8_validation", is_extension: false}], identifier_value: "NONE"}]}}, message[:field][0])
    entry = message[:nested_type][0]
    assert_equal "MyMapEntry", entry[:name]
    assert_equal({map_entry: true}, entry[:options])
    assert_equal %w[key value], entry[:field].map { |f| f[:name] }
    assert_equal "A", entry[:field][1][:type_name]
    refute_nil entry[:field][0][:options], "features are copied onto the key"
  end

  def test_groups_and_synthetic_oneofs
    ast = parse("syntax = \"proto2\";\nmessage A {\n  optional group Data = 1 { optional int32 x = 2; }\n}\n")
    message = AstHash.file(ast)[:message_type][0]
    assert_equal({name: "data", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_GROUP, type_name: "Data"}, message[:field][0])
    assert_equal "Data", message[:nested_type][0][:name]

    ast = parse("syntax = \"proto3\";\nmessage A {\n  optional int32 a = 1;\n  oneof o { int32 b = 2; }\n  optional int32 _a = 3;\n}\n")
    message = AstHash.file(ast)[:message_type][0]
    assert_equal %w[o X_a XX_a], message[:oneof_decl].map { |o| o[:name] }
    assert_equal [1, 0, 2], message[:field].map { |f| f[:oneof_index] }
  end

  def test_default_value_spelling
    ast = parse("syntax = \"proto2\";\nmessage A {\n" \
      "  optional double a = 1 [default = 1e10];\n" \
      "  optional bytes b = 2 [default = \"\\001\\n'\"];\n" \
      "  optional int32 c = 3 [default = -0x10];\n}\n")
    fields = AstHash.file(ast)[:message_type][0][:field]
    assert_equal ["10000000000", "\\001\\n\\'", "-16"], fields.map { |f| f[:default_value] }
  end

  def test_number_formatting_matches_protoc
    c = Protostar::Compiler
    assert_equal "0.1", c.simple_dtoa(0.1)
    assert_equal "1e+100", c.simple_dtoa(1e100)
    assert_equal "0.30000000000000004", c.simple_dtoa(0.1 + 0.2)
    assert_equal "-inf", c.simple_dtoa(-Float::INFINITY)
    assert_equal "2e+08", c.simple_ftoa(2e8)
    assert_equal "0.1", c.simple_ftoa(0.1)
    assert_equal "-8e-28", c.simple_ftoa(-8e-28)
    assert_equal "nan", c.simple_ftoa(Float::NAN)
    assert_equal "\\000\\001\\007\\010\\014\\n\\r\\t\\013\\\\\\'\\\"\\376", c.c_escape("\0\1\a\b\f\n\r\t\v\\'\"\xFE".b)
  end
end
