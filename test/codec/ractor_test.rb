# frozen_string_literal: true

require "test_helper"

class CodecRactorTest < Minitest::Test
  def setup
    @set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @set["proto2_unittest.TestAllTypes"]
  end

  # Ruby 4.0 replaced Ractor#take with Ractor#value
  def in_ractor(*args, &block)
    experimental = Warning[:experimental]
    Warning[:experimental] = false
    ractor = begin
      Ractor.new(*args, &block)
    ensure
      Warning[:experimental] = experimental
    end
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  end

  def test_classes_and_enum_modules_are_shareable
    @set.types.each_value { |type| assert Ractor.shareable?(type), "#{type.inspect} is not shareable" }
    assert Ractor.shareable?(@set["proto2_unittest.TestAllTypes.NestedEnum"])
  end

  def test_decode_and_encode_in_another_ractor
    source = RandomMessage.build(@all, random: Random.new(11), depth: 3, fill: 1.0)
    bytes = Ractor.make_shareable(source.encode)
    hash, encoded, enum_name, frozen_shareable = in_ractor(@all, bytes) do |klass, input|
      m = klass.decode(input)
      built = klass.new(optional_int32: 5, optional_nested_enum: :BAZ, repeated_string: ["a"])
      f = klass.decode(input, frozen: true)
      [m.to_h, klass.encode(m), built.optional_nested_enum, Ractor.shareable?(f)]
    end
    assert_equal source.to_h.keys, hash.keys
    assert_equal bytes, encoded
    assert_equal :BAZ, enum_name
    assert frozen_shareable
  end

  def test_frozen_message_crosses_the_boundary
    message = @all.new(optional_nested_message: {bb: 3}, repeated_string: ["a", "b"], optional_string: "s").freeze
    assert Ractor.shareable?(message)
    result = in_ractor(message) do |m|
      [m.optional_nested_message.bb, m.repeated_string, m.encode, m.frozen?]
    end
    assert_equal [3, ["a", "b"], message.encode, true], result
  end

  def test_frozen_decoded_message_crosses_the_boundary
    message = @all.decode(@all.new(optional_foreign_message: {c: 9}, repeated_int32: [1]).encode, frozen: true)
    assert_equal 9, in_ractor(message) { |m| m.optional_foreign_message.c }
  end

  def test_maps_and_closed_enums_in_another_ractor
    maps = CodecFixtures.load("google/protobuf/map_proto2_unittest.proto")
    plus = maps["proto2_unittest.TestEnumMapPlusExtra"]
    base = maps["proto2_unittest.TestEnumMap"]
    bytes = Ractor.make_shareable(plus.new(unknown_map_field: {1 => :E_PROTO2_MAP_ENUM_EXTRA}).encode)
    count = in_ractor(base, bytes) { |klass, input| klass.decode(input).unknown_fields.size }
    assert_equal 1, count
  end
end
