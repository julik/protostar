# frozen_string_literal: true

require "test_helper"

class ViewRactorTest < Minitest::Test
  def setup
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = set["proto2_unittest.TestAllTypes"]
    @maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
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

  def test_view_classes_are_shareable
    assert Ractor.shareable?(@all::View)
    assert Ractor.shareable?(Protostar::View::Repeated::EMPTY)
    assert Ractor.shareable?(Protostar::View::Map::EMPTY)
  end

  def test_frozen_view_crosses_the_boundary
    source = @all.new(optional_int32: 4, optional_string: "s", repeated_nested_message: [{bb: 1}, {bb: 2}], optional_nested_enum: :BAR)
    view = @all.view(source.encode.freeze).freeze_index
    assert Ractor.shareable?(view)
    result = in_ractor(view) do |v|
      [v.optional_int32, v.optional_string, v.repeated_nested_message.map(&:bb), v.optional_nested_enum, v.to_message.encode, v.to_h]
    end
    assert_equal [4, "s", [1, 2], :BAR, source.encode, source.to_h], result
  end

  def test_view_made_inside_a_ractor
    message = RandomMessage.build(@all, random: Random.new(9), depth: 3, fill: 1.0)
    bytes = Ractor.make_shareable(message.encode)
    map_bytes = Ractor.make_shareable(@maps.new(map_string_foreign_message: {"k" => {c: 5}}, map_int32_int32: {1 => 2}).encode)
    hash, unknown, map_values, shareable = in_ractor(@all, @maps, bytes, map_bytes) do |klass, maps, input, map_input|
      v = klass.view(input)
      m = maps.view(map_input)
      frozen = klass.view(input).freeze_index
      [v.to_h, v.unknown_fields.size, [m.map_string_foreign_message["k"].c, m.map_int32_int32.to_h], Ractor.shareable?(frozen)]
    end
    assert_equal ViewSupport.plain(message.__to_h), ViewSupport.plain(hash)
    assert_equal message.unknown_fields.size, unknown
    assert_equal [5, {1 => 2}], map_values
    assert shareable
  end

  def test_errors_inside_a_ractor
    error = in_ractor(@all) do |klass|
      klass.view("\x72\x05abc".b)
    rescue Protostar::DecodeError => e
      [e.class, e.offset]
    end
    assert_equal [Protostar::DecodeError, 2], error
  end
end
