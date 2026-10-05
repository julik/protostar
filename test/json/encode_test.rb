# frozen_string_literal: true

require "test_helper"

# Exact JSON for each rule of the mapping; the strings are what
# google-protobuf 4.36 prints for the same messages
class JSONEncodeTest < Minitest::Test
  def setup
    @set = CodecFixtures.load("google/protobuf/test_messages_proto3.proto")
    @all = @set["protobuf_test_messages.proto3.TestAllTypesProto3"]
    @maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    @proto3 = CodecFixtures.load("google/protobuf/unittest_proto3.proto")["proto3_unittest.TestAllTypes"]
  end

  def json(message, **options)
    message.class.encode_json(message, registry: @set.registry, **options)
  end

  def test_names_numbers_and_strings
    m = @all.new(optional_int32: -1, optional_int64: 5, optional_uint64: 2**64 - 1, optional_fixed32: 2**32 - 1,
      optional_bool: true, optional_string: "a <>&\"\\\u0001\u007f/é😀\t\n\b\f\r\u001f")
    assert_equal '{"optionalInt32":-1,"optionalInt64":"5","optionalUint64":"18446744073709551615",' \
      '"optionalFixed32":4294967295,"optionalBool":true,' \
      '"optionalString":"a' + " " + '<>&\"\\\\\u0001' + "\u007f" + '/é😀\t\n\b\f\r\u001f"}', json(m)
    assert_equal '{"optional_int32":-1}', json(@all.new(optional_int32: -1), preserve_proto_field_names: true)
    assert_equal '{"optional_int32":-1}', json(@all.new(optional_int32: -1), preserve_proto_fieldnames: true)
    assert_equal '{"fieldname1":1,"FieldName3":3,"fieldName4":4,"FIELDNAME11":11}',
      json(@all.new(fieldname1: 1, _field_name3: 3, field__name4_: 4, FIELD_NAME11: 11))
  end

  def test_floats_in_upb_round_trip_form
    m = @all.new(optional_float: 0.1, optional_double: 0.1,
      repeated_float: [1.401298464324817e-45, 3.4028234663852886e+38, 16777216.0, 1e10, -0.0],
      repeated_double: [1e300, 5e-324, 1.0, -0.0, 123456789012.0, 1e21, 1e-7, 0.3, 0.30000000000000004,
        Float::NAN, Float::INFINITY, -Float::INFINITY])
    assert_equal '{"optionalFloat":0.1,"optionalDouble":0.1,' \
      '"repeatedFloat":[1.4013e-45,3.40282347e+38,16777216,1e+10,-0],' \
      '"repeatedDouble":[1e+300,4.94065645841247e-324,1,-0,123456789012,1e+21,1e-07,0.3,0.30000000000000004,' \
      '"NaN","Infinity","-Infinity"]}', json(m)
    assert_equal '{"optionalDouble":-0}', json(@all.new(optional_double: -0.0)), "-0 is not a default"
  end

  def test_bytes_as_padded_standard_base64
    assert_equal '{"optionalBytes":"/wBhYvs="}', json(@all.new(optional_bytes: "\xFF\x00ab\xFB".b))
    assert_equal '{"repeatedBytes":["","YQ==","YWI="]}', json(@all.new(repeated_bytes: ["", "a", "ab"]))
  end

  def test_enums
    m = @all.new(optional_nested_enum: :BAZ, optional_foreign_enum: 7, repeated_nested_enum: [:FOO, :NEG, 99])
    assert_equal '{"optionalNestedEnum":"BAZ","optionalForeignEnum":7,"repeatedNestedEnum":["FOO","NEG",99]}', json(m)
    assert_equal '{"optionalNestedEnum":2,"optionalForeignEnum":7,"repeatedNestedEnum":[0,-1,99]}',
      json(m, format_enums_as_integers: true)
    assert_equal '{"optionalAliasedEnum":"ALIAS_BAZ"}', json(@all.new(optional_aliased_enum: :MOO)), "aliases print their first name"
  end

  def test_messages_maps_and_oneofs
    m = @all.new(optional_nested_message: {a: 1, corecursive: {}}, repeated_nested_message: [{}, {a: 2}],
      map_int32_int32: {1 => 2, -5 => 3}, map_bool_bool: {true => false}, map_int64_int64: {-1 => 2},
      map_string_nested_message: {"k" => {a: 3}}, oneof_uint32: 0)
    assert_equal '{"optionalNestedMessage":{"a":1,"corecursive":{}},"repeatedNestedMessage":[{},{"a":2}],' \
      '"mapInt32Int32":{"1":2,"-5":3},"mapInt64Int64":{"-1":"2"},"mapBoolBool":{"true":false},' \
      '"mapStringNestedMessage":{"k":{"a":3}},"oneofUint32":0}', json(m)
  end

  def test_emit_defaults_like_the_ruby_gem
    out = json(@all.new, emit_defaults: true)
    assert out.start_with?('{"optionalInt32":0,"optionalInt64":"0","optionalUint32":0,')
    assert_includes out, '"optionalNestedEnum":"FOO"'
    assert_includes out, '"repeatedInt32":[],'
    assert_includes out, '"mapInt32Int32":{},'
    assert_includes out, '"optionalNullValue":null'
    refute_includes out, "optionalNestedMessage", "unset message fields stay out"
    refute_includes out, "oneof", "unset oneof members stay out"
    assert_includes json(@all.new, emit_defaults: true, format_enums_as_integers: true), '"optionalNestedEnum":0'
    optional = CodecFixtures.load("google/protobuf/unittest_proto3_optional.proto")["proto2_unittest.TestProto3Optional"]
    out = json(optional.new, emit_defaults: true)
    assert_includes out, '"singularInt32":0'
    refute_includes out, "optionalInt32", "proto3 optional fields have presence and stay out when unset"
    assert_includes json(optional.new(optional_int32: 0), emit_defaults: true), '"optionalInt32":0'
  end

  def test_unknown_fields_are_never_written
    w = Protostar::Wire::Writer.new
    w.write_tag(9999, 0).write_varint(1)
    assert_equal "{}", json(@all.decode(w.string))
  end

  def test_other_files
    assert_equal '{"optionalInt32":1,"optionalNestedEnum":"BAZ","repeatedString":["x"]}',
      @proto3.encode_json(@proto3.new(optional_int32: 1, optional_nested_enum: :BAZ, repeated_string: ["x"]))
    assert_equal '{"mapStringString":{"b":"x","a":""},"mapInt32Enum":{"1":"MAP_ENUM_BAZ"}}',
      @maps.encode_json(@maps.new(map_string_string: {"b" => "x", "a" => ""}, map_int32_enum: {1 => :MAP_ENUM_BAZ}))
  end

  def test_conveniences
    m = @proto3.new(optional_int32: 1)
    assert_equal '{"optionalInt32":1}', m.to_json
    assert_equal '{"optional_int32":1}', m.to_json(preserve_proto_field_names: true)
    assert_equal '{"optionalInt32":1}', Protostar::JSON.encode(m)
    assert_equal '{"m":{"optionalInt32":1}}', ::JSON.generate({"m" => m}), "the json library's generator calls to_json"
    assert_raises(Protostar::TypeError) { @all.encode_json(m) }
  end
end
