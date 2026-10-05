# frozen_string_literal: true

require "test_helper"

# The special JSON forms of the well-known types, in both directions
class JSONWellKnownTest < Minitest::Test
  def setup
    @set = CodecFixtures.load("google/protobuf/test_messages_proto3.proto")
    @all = @set["protobuf_test_messages.proto3.TestAllTypesProto3"]
    @timestamp = @set["google.protobuf.Timestamp"]
    @duration = @set["google.protobuf.Duration"]
    @any = @set["google.protobuf.Any"]
    @value = @set["google.protobuf.Value"]
  end

  def json(message, **options)
    message.class.encode_json(message, registry: @set.registry, **options)
  end

  def decode(json, klass = @all, **options)
    klass.decode_json(json, registry: @set.registry, **options)
  end

  def assert_encode_error(pattern, message)
    e = assert_raises(Protostar::JSON::EncodeError) { json(message) }
    assert_match pattern, e.message
    e
  end

  def assert_parse_error(pattern, json, klass = @all)
    e = assert_raises(Protostar::JSON::ParseError) { decode(json, klass) }
    assert_match pattern, e.message
    e
  end

  def test_timestamp
    {
      [0, 0] => "1970-01-01T00:00:00Z", [1, 10_000_000] => "1970-01-01T00:00:01.010Z",
      [1, 500] => "1970-01-01T00:00:01.000000500Z", [1, 123_456_000] => "1970-01-01T00:00:01.123456Z",
      [-62_135_596_800, 0] => "0001-01-01T00:00:00Z", [253_402_300_799, 999_999_999] => "9999-12-31T23:59:59.999999999Z",
      [-1, 0] => "1969-12-31T23:59:59Z"
    }.each do |(seconds, nanos), text|
      ts = @timestamp.new(seconds: seconds, nanos: nanos)
      assert_equal %("#{text}"), json(ts)
      assert_equal ts, decode(%("#{text}"), @timestamp)
    end
    assert_equal 1, decode('"1970-01-01T01:00:01+01:00"', @timestamp).seconds
    assert_equal 30_601, decode('"1970-01-01T00:00:01-08:30"', @timestamp).seconds
    assert_equal 500_000_000, decode('"1970-01-01T00:00:01.5Z"', @timestamp).nanos
    assert_equal 5_184_000, decode('"1970-02-30T00:00:00Z"', @timestamp).seconds, "upb does not check the day of the month"
    assert_parse_error(/more than 9 fractional digits/, '"1970-01-01T00:00:01.1234567891Z"', @timestamp)
    assert_parse_error(/not an RFC 3339 timestamp/, '"1970-01-01t00:00:01z"', @timestamp)
    assert_parse_error(/not an RFC 3339 timestamp/, '"1970-01-01T00:00:01"', @timestamp)
    assert_parse_error(/out of the Timestamp range/, '"0000-01-01T00:00:00Z"', @timestamp)
    assert_parse_error(/expected an RFC 3339 timestamp string, got 5/, '{"optionalTimestamp": 5}')
    assert_encode_error(/before 0001-01-01/, @timestamp.new(seconds: -62_135_596_801))
    assert_encode_error(/after 9999-12-31/, @timestamp.new(seconds: 253_402_300_800))
    assert_encode_error(/nanos out of range: -1/, @timestamp.new(seconds: 1, nanos: -1))
  end

  def test_duration
    {
      [0, 0] => "0s", [1, 0] => "1s", [1, 500_000_000] => "1.500s", [-1, -500_000_000] => "-1.500s",
      [0, -1000] => "-0.000001s", [0, 1] => "0.000000001s", [315_576_000_000, 0] => "315576000000s",
      [-315_576_000_000, -999_999_999] => "-315576000000.999999999s"
    }.each do |(seconds, nanos), text|
      d = @duration.new(seconds: seconds, nanos: nanos)
      assert_equal %("#{text}"), json(d)
      assert_equal d, decode(%("#{text}"), @duration)
    end
    assert_equal [1, 0], decode('"1.s"', @duration).then { |d| [d.seconds, d.nanos] }
    assert_equal [0, 500_000_000], decode('".5s"', @duration).then { |d| [d.seconds, d.nanos] }
    assert_equal [0, -500_000_000], decode('"-0.5s"', @duration).then { |d| [d.seconds, d.nanos] }
    assert_parse_error(/is not a duration/, '"1"', @duration)
    assert_parse_error(/is not a duration/, '"+1s"', @duration)
    assert_parse_error(/more than 9 fractional digits/, '"1.0123456789s"', @duration)
    assert_parse_error(/out of the Duration range/, '"315576000001s"', @duration)
    assert_encode_error(/Duration out of range/, @duration.new(seconds: 315_576_000_001))
    assert_encode_error(/different signs/, @duration.new(seconds: 1, nanos: -1))
    assert_encode_error(/nanos out of range/, @duration.new(nanos: 1_000_000_000))
  end

  def test_field_mask
    mask = @set["google.protobuf.FieldMask"]
    assert_equal '"fooBar,baz.quxQuux,A"', json(mask.new(paths: ["foo_bar", "baz.qux_quux", "_a"]))
    assert_equal '""', json(mask.new)
    assert_equal %w[foo_bar baz.qux_quux], decode('"fooBar,baz.quxQuux"', mask).paths
    assert_equal [], decode('""', mask).paths
    assert_equal ["a", "", "b"], decode('"a,,b"', mask).paths
    assert_parse_error(/may not contain '_'/, '"foo_bar"', mask)
    assert_encode_error(/upper-case letter/, mask.new(paths: ["fooBar"]))
    %w[a__b a_1 a_b_].each { |p| assert_encode_error(/underscore not followed by a lower-case letter/, mask.new(paths: [p])) }
  end

  def test_struct_value_and_list_value
    json = '{"a":[1,"x",true,null,{"b":2.5}],"c":{}}'
    struct = decode(json, @set["google.protobuf.Struct"])
    assert_equal({"a" => [1.0, "x", true, nil, {"b" => 2.5}], "c" => {}}, struct.to_h)
    assert_equal json, json(struct)
    assert_equal '{"optionalValue":[]}', json(@all.new(optional_value: {list_value: {}}))
    assert_equal '{"optionalValue":{}}', json(@all.new(optional_value: {struct_value: {}}))
    assert_equal '{"optionalValue":3}', json(@all.new(optional_value: {number_value: 3.0}))
    assert_equal '{"optionalValue":null}', json(@all.new(optional_value: {null_value: :NULL_VALUE}))
    assert_equal "null", json(@value.new(null_value: :NULL_VALUE))
    assert_equal :NULL_VALUE, decode("null", @value).null_value
    assert_equal '{"optionalStruct":{"a":[null]}}', json(@all.new(optional_struct: {fields: {"a" => {list_value: {values: [{null_value: 0}]}}}}))
    assert_encode_error(/Value has no kind set/, @value.new)
    assert_encode_error(/Value cannot hold NaN/, @value.new(number_value: Float::NAN))
    assert_encode_error(/Value cannot hold Infinity/, @value.new(number_value: Float::INFINITY))
    e = assert_encode_error(/no kind set/, @all.new(optional_struct: {fields: {"a" => {}}}))
    assert_equal 'optional_struct["a"]', e.path
    assert_parse_error(/expected an object for google.protobuf.Struct, got an array/, '{"optionalStruct": []}')
    assert_parse_error(/out of range/, '{"optionalValue": 1e400}')
  end

  def test_wrappers
    m = decode('{"optionalBoolWrapper": false, "optionalInt64Wrapper": "5", "optionalBytesWrapper": "aGk=",
      "optionalDoubleWrapper": "NaN", "optionalStringWrapper": "s", "optionalUint32Wrapper": 3, "optionalFloatWrapper": null}')
    assert_equal false, m.optional_bool_wrapper.value
    assert_equal 5, m.optional_int64_wrapper.value
    assert_equal "hi", m.optional_bytes_wrapper.value
    assert m.optional_double_wrapper.value.nan?
    assert_nil m.optional_float_wrapper
    assert_equal '{"optionalBoolWrapper":false,"optionalInt64Wrapper":"5","optionalUint32Wrapper":3,' \
      '"optionalDoubleWrapper":"NaN","optionalStringWrapper":"s","optionalBytesWrapper":"aGk="}', json(m)
    assert_equal '{"optionalUint64Wrapper":"0"}', json(@all.new(optional_uint64_wrapper: {})), "an empty wrapper is its zero"
    assert_parse_error(/expected an integer, got an object/, '{"optionalInt32Wrapper": {"value": 3}}')
    assert_equal "7", json(@set["google.protobuf.Int32Value"].new(value: 7))
    assert_equal 7, decode("7", @set["google.protobuf.Int32Value"]).value
  end

  def test_empty_is_an_ordinary_message
    assert_equal '{"optionalEmpty":{}}', json(@all.new(optional_empty: {}))
    assert_parse_error(/google.protobuf.Empty has no field "a"/, '{"optionalEmpty": {"a": 1}}')
  end

  def test_any
    inner = @all.new(optional_int32: 5)
    any = @any.pack(inner)
    assert_equal '{"@type":"type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3","optionalInt32":5}', json(any)
    assert_equal any, decode(json(any), @any)
    assert_equal any, decode('{"optionalInt32": 5, "@type": "type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3"}', @any),
      "@type may come anywhere"
    custom = @any.pack(inner, "example.com/types")
    assert_equal "example.com/types/protobuf_test_messages.proto3.TestAllTypesProto3", custom.type_url
    assert_equal '{"@type":"example.com/types/protobuf_test_messages.proto3.TestAllTypesProto3","optionalInt32":5}', json(custom)
    assert_equal custom, decode(json(custom), @any)
  end

  def test_any_holding_well_known_types
    duration = @any.pack(@duration.new(seconds: 1))
    assert_equal '{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1s"}', json(duration)
    assert_equal duration, decode(json(duration), @any)
    nested = @any.pack(@any.pack(@set["google.protobuf.Int32Value"].new(value: 7)))
    assert_equal '{"@type":"type.googleapis.com/google.protobuf.Any","value":' \
      '{"@type":"type.googleapis.com/google.protobuf.Int32Value","value":7}}', json(nested)
    assert_equal nested, decode(json(nested), @any)
    empty = @any.pack(@set["google.protobuf.Empty"].new)
    assert_equal '{"@type":"type.googleapis.com/google.protobuf.Empty"}', json(empty), "Empty has no special form"
    assert_equal '{"@type":"type.googleapis.com/google.protobuf.Struct","value":{}}', json(@any.pack(@set["google.protobuf.Struct"].new))
    assert_equal "", decode('{"@type": "type.googleapis.com/google.protobuf.Duration"}', @any).value
  end

  def test_any_errors
    # conformance: Required.*.JsonInput.AnyWithNoType, which google-protobuf fails
    assert_equal "{}", @any.new.to_json
    assert_equal @any.new, decode("{}", @any)
    assert_encode_error(/bad type URL ""/, @any.new(value: "\x08\x01".b))
    assert_encode_error(/cannot find the type "no.Such"/, @any.new(type_url: "type.googleapis.com/no.Such"))
    assert_encode_error(/cannot decode the protobuf_test_messages.proto3.TestAllTypesProto3 inside Any/,
      @any.new(type_url: "x/protobuf_test_messages.proto3.TestAllTypesProto3", value: "\xFF".b))
    assert_parse_error(/Any has no "@type"/, '{"value": 1}', @any)
    assert_parse_error(/needs a '\/' and a non-empty host/, '{"@type": "noslash"}', @any)
    assert_parse_error(/cannot find the type "no.Such"/, '{"@type": "a/no.Such"}', @any)
    assert_parse_error(/Any holding a google.protobuf.Empty|google.protobuf.Empty has no field "value"/,
      '{"@type": "type.googleapis.com/google.protobuf.Empty", "value": {}}', @any)
    ignored = decode('{"@type": "x/protobuf_test_messages.proto3.TestAllTypesProto3", "nope": 1}', @any, ignore_unknown_fields: true)
    assert_equal "", ignored.value
    other = Protostar::Types::Registry.new
    e = assert_raises(Protostar::JSON::EncodeError) { @any.encode_json(@any.pack(@duration.new), registry: other) }
    assert_match(/cannot find the type "google.protobuf.Duration"/, e.message)
  end
end
