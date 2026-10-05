# frozen_string_literal: true

require "test_helper"

# What decode_json accepts and refuses, as google-protobuf 4.36 does
class JSONDecodeTest < Minitest::Test
  def setup
    @set = CodecFixtures.load("google/protobuf/test_messages_proto3.proto")
    @all = @set["protobuf_test_messages.proto3.TestAllTypesProto3"]
    @maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
  end

  def decode(json, **options)
    @all.decode_json(json, registry: @set.registry, **options)
  end

  def assert_error(pattern, json, path: nil, **options)
    e = assert_raises(Protostar::JSON::ParseError) { decode(json, **options) }
    assert_match pattern, e.message
    assert_equal path, e.path if path
    e
  end

  def test_field_names
    m = decode('{"optionalInt32": 1, "optional_int64": 2, "FieldName3": 3, "field__name4_": 4}')
    assert_equal [1, 2, 3, 4], [m.optional_int32, m.optional_int64, m._field_name3, m.field__name4_]
    assert_error(/has no field "nope"/, '{"nope": 1}')
    assert_equal 5, decode('{"nope": {"x": [1]}, "optionalInt32": 5}', ignore_unknown_fields: true).optional_int32
    assert_equal 2, decode('{"optionalInt32": 1, "optional_int32": 2}').optional_int32, "the last of a repeated name wins"
  end

  def test_integers
    m = decode('{"optionalInt32": "12", "optionalInt64": 100, "optionalUint32": 1.0, "optionalUint64": "18446744073709551615",
      "optionalSint32": 1e2, "optionalSfixed64": "-0", "optionalFixed32": "4294967295"}')
    assert_equal [12, 100, 1, 2**64 - 1, 100, 0, 2**32 - 1],
      [m.optional_int32, m.optional_int64, m.optional_uint32, m.optional_uint64, m.optional_sint32, m.optional_sfixed64, m.optional_fixed32]
    assert_error(/1.5 is not an integer/, '{"optionalInt32": 1.5}', path: "optional_int32")
    assert_error(/"1e2" is not an integer/, '{"optionalInt32": "1e2"}')
    assert_error(/" 1" is not an integer/, '{"optionalInt32": " 1"}')
    assert_error(/"0x10" is not an integer/, '{"optionalInt64": "0x10"}')
    assert_error(/2147483648 is out of range for int32/, '{"optionalInt32": 2147483648}')
    assert_error(/-1 is out of range/, '{"optionalUint32": -1}')
    assert_error(/18446744073709551616 is out of range for uint64/, '{"optionalUint64": "18446744073709551616"}')
    # an unquoted number goes through a double, as in upb
    assert_error(/9223372036854775807 is out of range/, '{"optionalInt64": 9223372036854775807}')
    assert_equal 2**63 - 1, decode('{"optionalInt64": "9223372036854775807"}').optional_int64
    assert_error(/expected an integer, got true/, '{"optionalInt32": true}')
  end

  def test_floats
    m = decode('{"optionalDouble": "1.5", "optionalFloat": "NaN", "repeatedDouble": ["Infinity", "-Infinity", 1e5, "1e5", "  2", -0]}')
    assert_equal 1.5, m.optional_double
    assert m.optional_float.nan?
    assert_equal [Float::INFINITY, -Float::INFINITY, 1e5, 1e5, 2.0, -0.0], m.repeated_double
    assert_equal(-0.0, decode('{"optionalDouble": -0}').optional_double)
    assert decode('{"optionalDouble": -0}').optional_double.to_s.start_with?("-")
    assert_equal 3.4028234663852886e+38, decode('{"optionalFloat": 3.4028235e38}').optional_float
    assert_error(/out of range for float/, '{"optionalFloat": 3.4028236e38}')
    assert_error(/1.0e\+400 is out of range|Infinity is out of range/, '{"optionalDouble": 1e400}')
    assert_error(/"1_0" is not a number/, '{"optionalDouble": "1_0"}')
    assert_error(/"" is not a number/, '{"optionalDouble": ""}')
    assert_equal 0.0, decode('{"optionalFloat": 1e-50}').optional_float
  end

  def test_bools_strings_and_bytes
    assert_equal true, decode('{"optionalBool": true}').optional_bool
    assert_error(/expected true or false, got "true"/, '{"optionalBool": "true"}')
    assert_error(/expected true or false, got 1/, '{"optionalBool": 1}')
    assert_error(/expected a string, got 5/, '{"optionalString": 5}')
    assert_equal "日本", decode('{"optionalString": "日本"}').optional_string
    {"-_8" => "\xFB\xFF", "+/8=" => "\xFB\xFF", "/w==" => "\xFF", "/w" => "\xFF", "YWJ" => "ab", "YR==" => "a", "" => ""}.each do |b64, bytes|
      assert_equal bytes.b, decode(%({"optionalBytes": "#{b64}"})).optional_bytes, b64
    end
    ["/w=", "Y", "YQ=x", "YW Jj", "!!"].each do |bad|
      assert_error(/is not base64/, %({"optionalBytes": "#{bad}"}))
    end
  end

  def test_enums
    m = decode('{"optionalNestedEnum": "BAZ", "repeatedNestedEnum": [1, "FOO", 99, 1.0], "optionalAliasedEnum": "MOO"}')
    assert_equal :BAZ, m.optional_nested_enum
    assert_equal [:BAR, :FOO, 99, :BAR], m.repeated_nested_enum
    assert_equal :ALIAS_BAZ, m.optional_aliased_enum
    assert_error(/has no value "NOPE"/, '{"optionalNestedEnum": "NOPE"}')
    assert_error(/has no value "1"/, '{"optionalNestedEnum": "1"}')
    assert_error(/2147483648 is out of range/, '{"optionalNestedEnum": 2147483648}')
    ignoring = {ignore_unknown_fields: true}
    assert_equal :FOO, decode('{"optionalNestedEnum": "NOPE"}', **ignoring).optional_nested_enum, "left at its default"
    assert_nil decode('{"oneofEnum": "NOPE"}', **ignoring).which_oneof_field
    assert_equal [:BAR], decode('{"repeatedNestedEnum": ["NOPE", "BAR"]}', **ignoring).repeated_nested_enum
    assert_equal({"b" => :BAR}, decode('{"mapStringNestedEnum": {"a": "NOPE", "b": "BAR"}}', **ignoring).map_string_nested_enum)
  end

  def test_null
    m = decode('{"optionalInt32": null, "optionalNestedMessage": null, "repeatedInt32": null, "mapInt32Int32": null,
      "optionalNestedEnum": null, "optionalValue": null, "repeatedValue": [null], "oneofNullValue": null}')
    assert_equal 0, m.optional_int32
    assert_nil m.optional_nested_message
    assert_equal [], m.repeated_int32
    assert_equal :NULL_VALUE, m.optional_value.null_value
    assert_equal [:null_value], m.repeated_value.map(&:which_kind)
    assert_equal :oneof_null_value, m.which_oneof_field
    assert_error(/null is not allowed here/, '{"repeatedInt32": [null]}', path: "repeated_int32[0]")
    assert_error(/null is not allowed here/, '{"mapInt32Int32": {"1": null}}', path: "map_int32_int32[\"1\"]")
  end

  def test_oneofs
    assert_equal "x", decode('{"oneofUint32": null, "oneofString": "x"}').oneof_string
    assert_error(/more than one field of oneof oneof_field is set/, '{"oneofUint32": 1, "oneofString": "x"}', path: "oneof_string")
  end

  def test_maps
    m = @maps.decode_json('{"mapInt32Int32": {"1": 2, "-5": 3}, "mapBoolBool": {"true": true, "false": false},
      "mapInt64Int64": {"-1": "5"}, "mapUint32Uint32": {"01": 5}, "mapStringForeignMessage": {"k": {"c": 1}}}')
    assert_equal({1 => 2, -5 => 3}, m.map_int32_int32)
    assert_equal({true => true, false => false}, m.map_bool_bool)
    assert_equal({-1 => 5}, m.map_int64_int64)
    assert_equal({1 => 5}, m.map_uint32_uint32)
    assert_equal 1, m.map_string_foreign_message["k"].c
    e = assert_raises(Protostar::JSON::ParseError) { @maps.decode_json('{"mapBoolBool": {"1": true}}') }
    assert_match(/map key "1" is not true or false/, e.message)
    e = assert_raises(Protostar::JSON::ParseError) { @maps.decode_json('{"mapInt32Int32": {"x": 1}}') }
    assert_match(/"x" is not an integer/, e.message)
  end

  def test_error_paths
    e = assert_error(/"x" is not an integer/, '{"repeatedNestedMessage": [{"a": 1}, {"corecursive": {"optionalInt32": "x"}}]}')
    assert_equal "repeated_nested_message[1].corecursive.optional_int32", e.path
    assert_equal 'repeated_nested_message[1].corecursive.optional_int32: "x" is not an integer', e.message
    e = assert_error(/expected an object/, '{"mapStringNestedMessage": {"k": []}}')
    assert_equal 'map_string_nested_message["k"]', e.path
  end

  def test_malformed_json
    assert_error(/invalid JSON/, '{"optionalInt32": 1')
    assert_error(/expected an object for protobuf_test_messages.proto3.TestAllTypesProto3, got an array/, "[]")
    assert_error(/expected an object/, "5")
    assert_error(/got null/, "null")
    assert_error(/invalid JSON/, '{"a": NaN}')
    assert_error(/not valid UTF-8/, "{\"optionalString\": \"\xFF\"}")
  end

  def test_round_trip_with_conveniences
    m = @all.new(optional_int32: 1, repeated_string: ["a"], map_string_string: {"k" => "v"}, oneof_bool: false)
    assert_equal m, @all.decode_json(m.to_json)
    assert_equal m, Protostar::JSON.decode(@all, m.to_json(preserve_proto_field_names: true))
  end
end
