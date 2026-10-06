# frozen_string_literal: true

require "test_helper"

# JSON and text format work inside other Ractors, like the binary codec;
# only Any and extensions, which need the registry, are main-Ractor only
class JSONTextRactorTest < Minitest::Test
  def setup
    @klass = CodecFixtures.load("google/protobuf/test_messages_proto3.proto")["protobuf_test_messages.proto3.TestAllTypesProto3"]
  end

  def test_json_and_text_in_another_ractor
    message = @klass.new(optional_int32: 5, optional_string: "é\n", repeated_double: [0.1, Float::NAN],
      map_string_nested_message: {"k" => {a: 1}}, optional_timestamp: {seconds: 1, nanos: 5}, optional_value: {list_value: {values: [{bool_value: true}]}})
    message.freeze
    # Also autoloads JSON and Text here, which Ruby 3.2 and 3.3 cannot do in another Ractor
    expected_json = message.to_json
    expected_text = message.to_text
    ractor = Ractor.new(@klass, message) do |klass, m|
      json = m.to_json
      text = m.to_text
      [json, text, klass.decode_json(json) == m, Protostar::Text.parse(klass, text) == m]
    end
    json, text, json_equal, text_equal = ractor.respond_to?(:value) ? ractor.value : ractor.take
    assert_equal expected_json, json
    assert_equal expected_text, text
    assert json_equal
    assert text_equal
  end
end
