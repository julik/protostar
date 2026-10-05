# frozen_string_literal: true

require "test_helper"

class TextParserTest < Minitest::Test
  def setup
    @set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @set["proto2_unittest.TestAllTypes"]
    @maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    @any_set = CodecFixtures.load("google/protobuf/any_test.proto")
  end

  def parse(text, klass = @all, **options)
    Protostar::Text.parse(klass, text, registry: @set.registry, **options)
  end

  def assert_parse_error(pattern, text, klass = @all, **options)
    e = assert_raises(Protostar::Text::ParseError) { parse(text, klass, **options) }
    assert_match pattern, e.message
    e
  end

  def test_integers_in_every_base
    m = parse("optional_int32: 0x1F optional_int64: -017 optional_uint32: 0 optional_uint64: 0XFFFFFFFFFFFFFFFF")
    assert_equal [31, -15, 0, 2**64 - 1], [m.optional_int32, m.optional_int64, m.optional_uint32, m.optional_uint64]
  end

  def test_integer_ranges
    assert_equal(-2**31, parse("optional_sfixed32: -2147483648").optional_sfixed32)
    assert_parse_error(/integer out of range/, "optional_int32: 2147483648")
    assert_parse_error(/expected an integer, got "-"/, "optional_uint32: -1")
    assert_parse_error(/expected an integer, got "1.0"/, "optional_int32: 1.0")
    assert_parse_error(/leading zero must be in octal/, "optional_int32: 09")
  end

  def test_floats
    m = parse("optional_float: 1.5f optional_double: .5e1 repeated_double: [-inf, Infinity, nan, 1, -0]")
    assert_equal 1.5, m.optional_float
    assert_equal 5.0, m.optional_double
    d = m.repeated_double
    assert_equal [-Float::INFINITY, Float::INFINITY], d[0, 2]
    assert d[2].nan?
    assert_equal 1.0, d[3]
    assert_equal(-0.0, d[4])
    assert d[4].to_s.start_with?("-")
    assert_parse_error(/expected a decimal number, got "0x10"/, "optional_double: 0x10")
    assert_equal 3.4028234663852886e+38, parse("optional_float: 3.40282347e+38").optional_float
  end

  def test_booleans
    m = parse("repeated_bool: [true, True, t, 1, false, False, f, 0]")
    assert_equal [true] * 4 + [false] * 4, m.repeated_bool
    assert_parse_error(/invalid value for a boolean field: "2"/, "optional_bool: 2")
    assert_parse_error(/invalid value for a boolean field: "yes"/, "optional_bool: yes")
  end

  def test_strings_concatenate_and_unescape
    m = parse(%(optional_string: "a" 'b' "\\t\\"\\'\\\\\\?" "\\101\\x42\\u00e9\\U0001F600" "日本"))
    assert_equal "ab\t\"'\\?ABé😀日本", m.optional_string
    assert_equal Encoding::UTF_8, m.optional_string.encoding
    m = parse(%(optional_bytes: "\\0\\377\\x7" ''))
    assert_equal "\x00\xFF\x07".b, m.optional_bytes
    assert_parse_error(/invalid escape sequence "\\q"/, %(optional_string: "\\q"))
    assert_parse_error(/string is not valid UTF-8/, %(optional_string: "\\377"))
    assert_parse_error(/unterminated string/, %(optional_string: "abc))
  end

  # conformance: Recommended.*.TextFormatInput.StringLiteral*UnicodeEscapeSurrogate*
  def test_surrogate_escapes_are_refused
    %w[\\ud800 \\udc00 \\U0000d800 \\ud801\\udc37 \\U0000d801\\udc37].each do |escape|
      assert_parse_error(/Unicode escape of surrogate U\+D[89A-F]/, %(optional_bytes: "#{escape}"))
      assert_parse_error(/Unicode escape of surrogate/, %(optional_string: "#{escape}"))
    end
    assert_equal "\u{10437}".b, parse(%(optional_bytes: "\\U00010437")).optional_bytes
  end

  # conformance: Required.*.TextFormatInput.ReservedFieldName.*
  def test_reserved_field_names_are_skipped
    reserved = @set["proto2_unittest.TestReservedFields"]
    m = parse("bar: 1 baz { a: [1, 2] } bar: [1.5, 'x'] bar < x: y >", reserved)
    assert_equal reserved.new, m
    assert_empty m.unknown_fields
    assert_parse_error(/has no field named "foo"/, "foo: 1", reserved)
  end

  def test_enums_by_name_and_number
    m = parse("optional_nested_enum: BAZ repeated_nested_enum: [1, NEG, -1]")
    assert_equal :BAZ, m.optional_nested_enum
    assert_equal %i[FOO NEG NEG], m.repeated_nested_enum
    # closed enums refuse numbers without a name; open ones keep them
    assert_parse_error(/unknown enumeration value of "99" for field "optional_nested_enum"/, "optional_nested_enum: 99")
    assert_parse_error(/unknown enumeration value of "QUUX"/, "optional_nested_enum: QUUX")
    proto3 = CodecFixtures.load("google/protobuf/unittest_proto3.proto")["proto3_unittest.TestAllTypes"]
    assert_equal 99, parse("optional_nested_enum: 99", proto3).optional_nested_enum
  end

  def test_messages_braces_lists_and_separators
    m = parse(<<~TEXT)
      optional_nested_message: { bb: 1 };
      optional_foreign_message < c: 2 >,
      repeated_nested_message [{bb: 3}, <bb: 4>]
      repeated_nested_message: [{bb: 5}]
      repeated_int32: [] repeated_int32: [1, 2] repeated_int32: 3
      OptionalGroup { a: 6 }
      repeatedgroup { a: 7 } RepeatedGroup { a: 8 }
    TEXT
    assert_equal 1, m.optional_nested_message.bb
    assert_equal 2, m.optional_foreign_message.c
    assert_equal [3, 4, 5], m.repeated_nested_message.map(&:bb)
    assert_equal [1, 2, 3], m.repeated_int32
    assert_equal 6, m.optionalgroup.a
    assert_equal [7, 8], m.repeatedgroup.map(&:a)
    assert_parse_error(/expected "\{" or "<" after "optional_nested_message:", got "\["/, "optional_nested_message: [{}]")
    assert_parse_error(/has no field named "Optional_group"/, "Optional_group { a: 1 }")
  end

  def test_comments_and_whitespace
    m = parse("# leading\noptional_int32: # inside\n  5 # trailing\n# end")
    assert_equal 5, m.optional_int32
    assert_equal 0, parse("").optional_int32
  end

  def test_maps
    m = parse(<<~TEXT, @maps)
      map_int32_int32 { key: 2 value: 1 }
      map_int32_int32 [{ key: 1 }, { value: 3 }]
      map_int32_int32 { key: 2 value: 9 }
      map_string_foreign_message { key: "a" value { c: 1 } }
      map_string_foreign_message { key: "b" }
      map_bool_bool { key: true }
      map_int32_enum { key: 1 value: MAP_ENUM_BAZ }
    TEXT
    assert_equal({2 => 9, 1 => 0, 0 => 3}, m.map_int32_int32, "a repeated key keeps the last value")
    assert_equal 1, m.map_string_foreign_message["a"].c
    assert_equal 0, m.map_string_foreign_message["b"].c
    assert_equal({true => false}, m.map_bool_bool)
    assert_equal({1 => :MAP_ENUM_BAZ}, m.map_int32_enum)
    assert_parse_error(/map entry has no field named "other"/, "map_int32_int32 { other: 1 }", @maps)
  end

  def test_oneofs_and_repeated_singular_fields_are_refused
    e = assert_parse_error(/field "oneof_string" is specified along with field "oneof_uint32", another member of oneof "oneof_field"/,
      "oneof_uint32: 1\noneof_string: \"x\"")
    assert_equal [2, 1], [e.line, e.column]
    assert_parse_error(/non-repeated field "optional_int32" is specified multiple times/, "optional_int32: 1 optional_int32: 2")
    assert_parse_error(/non-repeated field "optional_nested_message" is specified multiple times/,
      "optional_nested_message {} optional_nested_message {}")
  end

  def test_errors_name_line_and_column
    e = assert_parse_error(/\A3:3: message type "proto2_unittest.TestAllTypes" has no field named "nope"\z/,
      "optional_int32: 1\n\n  nope: 1")
    assert_equal [3, 3], [e.line, e.column]
    assert_parse_error(/\A1:16: expected ":", got "1"\z/, "optional_int32 1")
    assert_parse_error(/\A1:20: expected ",", got "2"\z/, "repeated_int32: [1 2]")
    assert_parse_error(/expected "\}", got end of input/, "optional_nested_message { bb: 1")
    assert_parse_error(/expected an integer, got "1f"/, "optional_int32: 1f")
    assert_parse_error(/need space between number and identifier/, "optional_int32: 1x")
    assert_parse_error(/expected a field name, got "\}"/, "}")
  end

  def test_unknown_fields_are_skipped_when_allowed
    text = <<~TEXT
      nope: 1
      optional_int32: 5
      nested_nope { a: [1, 2] b < c: "x" 'y' > d: -inf }
      list_nope: [1, -2, "three"]
      list_of_messages: [{ x: 1 }]
      [unknown.extension]: 3
      [other.ext] { y: 2 }
      optional_int64: 6
    TEXT
    m = parse(text, allow_unknown_fields: true)
    assert_equal [5, 6], [m.optional_int32, m.optional_int64]
    assert_parse_error(/has no field named "nope"/, text)
  end

  def test_extensions_become_unknown_fields
    extendable = @set["proto2_unittest.TestAllExtensions"]
    m = parse(<<~TEXT, extendable)
      [proto2_unittest.optional_int32_extension]: 101
      [proto2_unittest.repeated_string_extension]: ["a", "b"]
      [proto2_unittest.optional_nested_message_extension] { bb: 5 }
      [proto2_unittest.optionalgroup_extension] { a: 7 }
    TEXT
    bytes = m.encode
    reference = parse(<<~TEXT, extendable)
      [proto2_unittest.optionalgroup_extension] { a: 7 }
      [proto2_unittest.optional_nested_message_extension] { bb: 5 }
      [proto2_unittest.repeated_string_extension]: "a"
      [proto2_unittest.optional_int32_extension]: 101
      [proto2_unittest.repeated_string_extension]: "b"
    TEXT
    assert_equal bytes, reference.encode, "extensions are written in number order"
    assert_equal [1, 16, 18, 44, 44], m.unknown_fields.map(&:number)
    assert_parse_error(/extension "proto2_unittest.nope" is not known to proto2_unittest.TestAllExtensions/,
      "[proto2_unittest.nope]: 1", extendable)
    assert_parse_error(/non-repeated field "proto2_unittest.optional_int32_extension" is specified multiple times/,
      "[proto2_unittest.optional_int32_extension]: 1 [proto2_unittest.optional_int32_extension]: 2", extendable)
  end

  def test_packed_extensions_are_written_packed
    packed = @set["proto2_unittest.TestPackedExtensions"]
    m = parse("[proto2_unittest.packed_int32_extension]: [1, 2] [proto2_unittest.packed_int32_extension]: 300", packed)
    assert_equal ["\x04\x01\x02\xAC\x02".b], m.unknown_fields.map(&:bytes)
  end

  def test_any_expanded_form
    test_any = @any_set["proto2_unittest.TestAny"]
    text = %(any_value { [example.com/x/proto2_unittest.TestAny] { int32_value: 7 } })
    m = Protostar::Text.parse(test_any, text, registry: @any_set.registry)
    assert_equal "example.com/x/proto2_unittest.TestAny", m.any_value.type_url
    assert_equal 7, test_any.decode(m.any_value.value).int32_value
    e = assert_raises(Protostar::Text::ParseError) do
      Protostar::Text.parse(test_any, "any_value { [type.googleapis.com/no.Such] {} }", registry: @any_set.registry)
    end
    assert_match(/could not find the type "no.Such" of an Any/, e.message)
    e = assert_raises(Protostar::Text::ParseError) do
      Protostar::Text.parse(test_any, "[type.googleapis.com/proto2_unittest.TestAny] {}", registry: @any_set.registry)
    end
    assert_match(/expands an Any, but this is a proto2_unittest.TestAny/, e.message)
  end

  # conformance: Required.*.TextFormatInput.AnyFieldWith{SpecialCharacters,ValidUrlPercentEscape}InTypeUrlPrefix
  def test_any_type_url_prefixes_take_url_characters
    test_any = @any_set["proto2_unittest.TestAny"]
    parse_any = ->(url) { Protostar::Text.parse(test_any, "any_value { [#{url}] { int32_value: 7 } }", registry: @any_set.registry) }
    ["a.b/sub-path_0/~!$&()*+,;=/proto2_unittest.TestAny", "a.b/%2F/proto2_unittest.TestAny"].each do |url|
      assert_equal url, parse_any.call(url).any_value.type_url
    end
    assert_equal "a.b/c/proto2_unittest.TestAny", parse_any.call("a.b / c/ # comment\n proto2_unittest . TestAny").any_value.type_url
    {
      "a/%2/proto2_unittest.TestAny" => /invalid percent escape "%2\/"/,
      "a/%zz/proto2_unittest.TestAny" => /invalid percent escape "%zz"/,
      "/proto2_unittest.TestAny" => /type URL prefix is empty/,
      "a/proto2_unittest.1Any" => /invalid type name "proto2_unittest.1Any"/,
      "a/b?c/proto2_unittest.TestAny" => /unexpected "\?" in a bracketed name/
    }.each do |url, error|
      e = assert_raises(Protostar::Text::ParseError, url) { parse_any.call(url) }
      assert_match error, e.message
    end
    assert_parse_error(/invalid type name "proto2_unittest..x"/, "[proto2_unittest..x]: 1", @set["proto2_unittest.TestAllExtensions"])
  end

  def test_required_fields_with_allow_partial
    required = @set["proto2_unittest.TestRequired"]
    assert_equal 1, parse("a: 1", required).a
    assert_parse_error(/missing required fields/, "a: 1", required, allow_partial: false)
    assert_equal 3, parse("a: 1 b: 2 c: 3", required, allow_partial: false).c
  end
end
