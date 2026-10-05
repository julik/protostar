# frozen_string_literal: true

require "test_helper"

class TextPrinterTest < Minitest::Test
  def setup
    @set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @set["proto2_unittest.TestAllTypes"]
    @empty = @set["proto2_unittest.TestEmptyMessage"]
    @any_set = CodecFixtures.load("google/protobuf/any_test.proto")
  end

  def print(message, **options)
    Protostar::Text.print(message, registry: @set.registry, **options)
  end

  def test_layout_follows_field_numbers
    m = @all.new(repeated_int32: [1, 2], optional_int32: 5, optional_nested_message: {bb: 3}, optionalgroup: {a: 4},
      repeated_nested_message: [{}, {bb: 1}])
    assert_equal <<~TEXT, print(m)
      optional_int32: 5
      OptionalGroup {
        a: 4
      }
      optional_nested_message {
        bb: 3
      }
      repeated_int32: 1
      repeated_int32: 2
      repeated_nested_message {
      }
      repeated_nested_message {
        bb: 1
      }
    TEXT
    assert_equal "optional_int32: 5 OptionalGroup { a: 4 } optional_nested_message { bb: 3 } " \
      "repeated_int32: 1 repeated_int32: 2 repeated_nested_message { } repeated_nested_message { bb: 1 }",
      print(m, single_line: true)
    assert_equal "", print(@all.new)
    assert_equal m.to_text(registry: @set.registry), print(m)
  end

  def test_scalars
    m = @all.new(optional_float: 0.1, optional_double: 1e300, optional_bool: true, optional_uint64: 2**64 - 1,
      optional_sint32: -5, optional_nested_enum: :NEG, repeated_float: [Float::NAN, -Float::INFINITY, -0.0, 1.401298464324817e-45],
      repeated_double: [5e-324, 0.30000000000000004, 123456789012.0])
    assert_equal <<~TEXT, print(m)
      optional_uint64: 18446744073709551615
      optional_sint32: -5
      optional_float: 0.1
      optional_double: 1e+300
      optional_bool: true
      optional_nested_enum: NEG
      repeated_float: nan
      repeated_float: -inf
      repeated_float: -0
      repeated_float: 1.40129846e-45
      repeated_double: 4.94065645841247e-324
      repeated_double: 0.30000000000000004
      repeated_double: 123456789012
    TEXT
  end

  def test_strings_are_escaped_like_cescape
    m = @all.new(optional_string: "tab\t\"q\" 'a' \\ é\u0001\u007f", optional_bytes: "\x00\xFF\n".b)
    assert_equal <<~'TEXT', print(m)
      optional_string: "tab\t\"q\" \'a\' \\ \303\251\001\177"
      optional_bytes: "\000\377\n"
    TEXT
    assert_equal %(optional_string: "tab\\t\\"q\\" \\'a\\' \\\\ é\\001\\177"\noptional_bytes: "\\000\\377\\n"\n),
      print(m, as_utf8: true), "as_utf8 keeps UTF-8 in strings, not in bytes"
  end

  def test_unknown_fields_like_protoc
    w = Protostar::Wire::Writer.new
    w.write_tag(1, 0).write_varint(2**64 - 1)
    w.write_tag(2, 5).write_fixed32(0x3dcccccd)
    w.write_tag(3, 1).write_fixed64(1)
    w.write_tag(4, 2).write_bytes("\x08\x96\x01".b)
    w.write_tag(5, 2).write_bytes("not fields")
    w.write_tag(6, 2).write_bytes("")
    w.write_tag(7, 3).write_tag(1, 0).write_varint(1).write_tag(8, 3).write_tag(8, 4).write_tag(7, 4)
    m = @empty.decode(w.string)
    assert_equal <<~TEXT, print(m)
      1: 18446744073709551615
      2: 0x3dcccccd
      3: 0x0000000000000001
      4 {
        1: 150
      }
      5: "not fields"
      6: ""
      7 {
        1: 1
        8 {
        }
      }
    TEXT
  end

  def test_extensions_print_by_name
    m = Protostar::Text.parse(@set["proto2_unittest.TestAllExtensions"], <<~TEXT, registry: @set.registry)
      [proto2_unittest.repeated_int32_extension]: [1, 2]
      [proto2_unittest.optional_nested_enum_extension]: BAZ
      [proto2_unittest.optional_int32_extension]: 7
    TEXT
    assert_equal <<~TEXT, print(m)
      [proto2_unittest.optional_int32_extension]: 7
      [proto2_unittest.optional_nested_enum_extension]: BAZ
      [proto2_unittest.repeated_int32_extension]: 1
      [proto2_unittest.repeated_int32_extension]: 2
    TEXT
    pool = Protostar::Schema::Pool.new
    assert_equal "1: 7\n21: 3\n31: 1\n31: 2\n", print(m, pool: pool), "only extensions the pool knows are named"
  end

  def test_unknown_fields_can_be_hidden_while_extensions_still_print
    w = Protostar::Wire::Writer.new
    w.write_tag(1, 0).write_varint(7)
    w.write_tag(9999, 0).write_varint(1)
    w.write_tag(18, 2).write_bytes(Protostar::Wire::Writer.new.write_tag(9999, 0).write_varint(2).string)
    m = @set["proto2_unittest.TestAllExtensions"].decode(w.string)
    assert_equal <<~TEXT, print(m, unknown_fields: false)
      [proto2_unittest.optional_int32_extension]: 7
      [proto2_unittest.optional_nested_message_extension] {
      }
    TEXT
    assert_includes print(m), "9999: 1"
  end

  def test_extension_bytes_that_do_not_fit_stay_unknown
    w = Protostar::Wire::Writer.new
    w.write_tag(1, 2).write_bytes("oops")
    m = @set["proto2_unittest.TestAllExtensions"].decode(w.string)
    assert_equal "1: \"oops\"\n", print(m)
  end

  def test_any_expansion
    test_any = @any_set["proto2_unittest.TestAny"]
    inner = test_any.new(int32_value: 7, text: "x")
    m = test_any.new(any_value: {type_url: "example.com/types/proto2_unittest.TestAny", value: inner.encode},
      repeated_any_value: [{type_url: "type.googleapis.com/no.Such", value: "\x01".b}])
    expanded = <<~TEXT
      any_value {
        [example.com/types/proto2_unittest.TestAny] {
          int32_value: 7
          text: "x"
        }
      }
      repeated_any_value {
        type_url: "type.googleapis.com/no.Such"
        value: "\\001"
      }
    TEXT
    assert_equal expanded, Protostar::Text.print(m, registry: @any_set.registry)
    plain = Protostar::Text.print(m, registry: @any_set.registry, expand_any: false)
    assert_includes plain, %(type_url: "example.com/types/proto2_unittest.TestAny")
    assert_equal m, Protostar::Text.parse(test_any, expanded, registry: @any_set.registry)
  end

  def test_maps_sorted_by_key
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    m = maps.new(map_int32_int32: {5 => 1, -1 => 2}, map_bool_bool: {true => true, false => true},
      map_string_string: {"b" => "", "a" => "x"}, map_int32_foreign_message: {1 => {}})
    assert_equal <<~TEXT, print(m)
      map_int32_int32 {
        key: -1
        value: 2
      }
      map_int32_int32 {
        key: 5
        value: 1
      }
      map_bool_bool {
        key: false
        value: true
      }
      map_bool_bool {
        key: true
        value: true
      }
      map_string_string {
        key: "a"
        value: "x"
      }
      map_string_string {
        key: "b"
        value: ""
      }
      map_int32_foreign_message {
        key: 1
        value {
        }
      }
    TEXT
  end

  def test_delimited_fields_that_are_not_group_like_print_their_field_name
    set = CodecFixtures.load("google/protobuf/unittest_delimited.proto")
    klass = set["editions_unittest.TestDelimited"]
    m = klass.new(grouplike: {a: 1}, notgrouplike: {a: 2})
    text = Protostar::Text.print(m, registry: set.registry)
    assert_includes text, "GroupLike {"
    assert_includes text, "notgrouplike {"
    assert_equal m, Protostar::Text.parse(klass, text, registry: set.registry)
  end
end
