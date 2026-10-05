# frozen_string_literal: true

require "test_helper"
require "json"

# Message#to_json given the stdlib generator's state
class JsonPrettyTest < Minitest::Test
  def all_types
    CodecFixtures.load("google/protobuf/test_messages_proto3.proto")["protobuf_test_messages.proto3.TestAllTypesProto3"]
  end

  def sample
    all_types.new(
      optional_int32: 1, optional_string: "a,b:{c}[d]\"", optional_double: 1e300,
      optional_nested_message: {a: 5}, repeated_int32: [1, 2], repeated_nested_message: [{a: 1}, {}],
      map_string_string: {"k" => "v"}
    )
  end

  def test_pretty_generate_indents
    m = sample
    assert_equal ::JSON.pretty_generate(::JSON.parse(m.to_json)).gsub("1.0e+300", "1e+300"), ::JSON.pretty_generate(m)
    assert_includes ::JSON.pretty_generate(m), %("optionalDouble": 1e+300), "numbers keep the encoder's spelling"
    assert_includes ::JSON.pretty_generate(all_types.new(optional_float: -0.0)), %("optionalFloat": -0\n), "negative zero keeps its sign"
    assert_equal m, all_types.decode_json(::JSON.pretty_generate(m))
  end

  def test_nested_in_other_values_the_depth_is_honoured
    m = all_types.new(optional_int32: 1, repeated_int32: [2])
    assert_equal ::JSON.pretty_generate("x" => [::JSON.parse(m.to_json), {}]), ::JSON.pretty_generate("x" => [m, all_types.new])
  end

  def test_compact_generation_and_options_are_unchanged
    m = sample
    assert_equal m.to_json, ::JSON.generate(m)
    assert_equal m.to_json, m.to_json(::JSON::State.new)
    assert_equal ::JSON.pretty_generate(::JSON.parse(m.to_json(preserve_proto_field_names: true))).gsub("1.0e+300", "1e+300"),
      m.to_json(::JSON::State.new(indent: "  ", space: " ", object_nl: "\n", array_nl: "\n"), preserve_proto_field_names: true)
  end

  def test_layout_matches_the_stdlib_generator
    docs = [
      {"a" => [1, {"b" => []}], "c" => {}, "d" => "x,{}[]:\"\\"}, [], {},
      [[1, [2]], {"k" => {"j" => [3]}}]
    ]
    states = [
      {indent: "\t", object_nl: "\n"}, {array_nl: "\n"}, {indent: "  ", space: " ", object_nl: "\n", array_nl: "\n"},
      {space_before: " ", space: " "}, {indent: "  "}
    ]
    docs.each do |doc|
      states.each do |options|
        assert_equal ::JSON.generate(doc, options),
          Protostar::JSON.layout(::JSON.generate(doc), ::JSON::State.new(options)), [doc, options].inspect
      end
    end
  end
end
