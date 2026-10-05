# frozen_string_literal: true

require_relative "builder_support"

# proto2: groups, closed enums, explicit defaults, packed and unpacked repeated fields
class BuilderProto2Test < Minitest::Test
  include BuilderSupport

  def setup
    @set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @set["proto2_unittest.TestAllTypes"]
  end

  def test_groups_are_written_between_their_tags
    bytes = build(@all) do |pb|
      pb.optional_int32 1
      pb.optionalgroup { pb.a 17 }
      pb.repeatedgroup([1, 2]) { |i| pb.a i }
    end
    expected = @all.new(optional_int32: 1, optionalgroup: {a: 17}, repeatedgroup: [{a: 1}, {a: 2}])
    assert_equal expected.encode, bytes
  end

  def test_groups_from_hashes_and_instances
    group = @set["proto2_unittest.TestAllTypes.OptionalGroup"].new(a: 3)
    expected = @all.new(optionalgroup: {a: 3}, repeatedgroup: [{a: 4}, {a: 5}]).encode
    assert_equal expected, build(@all) { |pb| pb.optionalgroup(group).repeatedgroup([{a: 4}, @set["proto2_unittest.TestAllTypes.RepeatedGroup"].new(a: 5)]) }
  end

  def test_cache_inside_groups
    store = Store.new
    2.times do
      bytes = build(@all, cache_store: store) do |pb|
        pb.optionalgroup { pb.cache!("g") { pb.a 9 } }
      end
      assert_equal @all.new(optionalgroup: {a: 9}).encode, bytes
    end
  end

  def test_fields_with_presence_are_written_at_their_default
    bytes = build(@all) do |pb|
      pb.optional_int32 0
      pb.optional_string ""
      pb.default_int32 41
    end
    assert_equal @all.new(optional_int32: 0, optional_string: "", default_int32: 41).encode, bytes
  end

  def test_unpacked_repeated_scalars_are_written_as_they_come
    bytes = build(@all) do |pb|
      pb.repeated_int32 [1, 2]
      pb.repeated_nested_enum [:FOO, :BAR]
    end
    assert_equal @all.new(repeated_int32: [1, 2], repeated_nested_enum: [:FOO, :BAR]).encode, bytes
  end

  def test_packed_proto2
    packed = @set["proto2_unittest.TestPackedTypes"]
    bytes = build(packed) do |pb|
      pb.packed_int32 [1, -1]
      pb.packed_sint64 [-2]
      pb.packed_fixed32 [3]
      pb.packed_float [1.5]
      pb.packed_bool [true]
      pb.packed_enum [:FOREIGN_BAR]
    end
    expected = packed.new(packed_int32: [1, -1], packed_sint64: [-2], packed_fixed32: [3], packed_float: [1.5],
      packed_bool: [true], packed_enum: [:FOREIGN_BAR])
    assert_equal expected.encode, bytes
  end

  def test_closed_enums_refuse_unknown_numbers
    error = assert_raises(Protostar::Builder::Error) { build(@all) { |pb| pb.optional_nested_enum 99 } }
    assert_equal "optional_nested_enum: expects a value of proto2_unittest.TestAllTypes.NestedEnum, got 99", error.message
    assert_equal @all.new(optional_nested_enum: :NEG).encode, build(@all) { |pb| pb.optional_nested_enum(-1) }
  end
end
