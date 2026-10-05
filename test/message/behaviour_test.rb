# frozen_string_literal: true

require "test_helper"

class BehaviourTest < Minitest::Test
  def setup
    @unittest = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @unittest["proto2_unittest.TestAllTypes"]
    @all3 = CodecFixtures.load("google/protobuf/unittest_proto3.proto")["proto3_unittest.TestAllTypes"]
  end

  def sample
    @all.new(
      optional_int32: 1, optional_string: "x", optional_bytes: "\x00".b, optional_nested_enum: :BAZ,
      optional_nested_message: {bb: 5}, repeated_int32: [1, 2], repeated_nested_message: [{bb: 1}],
      optionalgroup: {a: 7}, oneof_string: "o"
    )
  end

  def test_to_h
    assert_equal({
      optional_int32: 1, optional_string: "x", optional_bytes: "\x00".b, optionalgroup: {a: 7},
      optional_nested_message: {bb: 5}, optional_nested_enum: :BAZ, repeated_int32: [1, 2],
      repeated_nested_message: [{bb: 1}], oneof_string: "o"
    }, sample.to_h)
    assert_equal({}, @all.new.to_h)
    assert_equal({optional_int32: 0}, @all.new(optional_int32: 0).to_h, "set fields with presence are included")
    assert_equal({}, @all3.new(optional_int32: 0, repeated_int32: []).to_h)
    assert_equal({optional_nested_enum: 42}, @all3.new(optional_nested_enum: 42).to_h)
  end

  def test_to_h_does_not_expose_storage
    m = sample
    m.to_h[:repeated_int32] << 3
    assert_equal [1, 2], m.repeated_int32
  end

  def test_to_h_round_trips_through_new
    m = sample
    assert_equal m, @all.new(m.to_h)
  end

  def test_equality
    assert_equal sample, sample
    assert sample.eql?(sample)
    assert_equal sample.hash, sample.hash
    refute_equal sample, @all.new
    refute_equal @all.new(optional_int32: 0), @all.new, "presence counts"
    assert_equal @all.new(repeated_int32: []), @all.new, "an empty repeated field equals an unset one"
    refute_equal @all3.new, @all.new, "different classes"
    refute_equal @all.new, nil
    a = @all.decode(sample.encode + "\xA0\x06\x01".b)
    assert_equal sample, a, "unknown fields are ignored"
    refute_empty a.unknown_fields
    assert_equal({sample => 1}[a], 1)
  end

  def test_nan_equals_nan
    a = @all.new(optional_double: Float::NAN, optional_float: Float::NAN, repeated_double: [Float::NAN, 1.0])
    b = @all.new(optional_double: Float::NAN, optional_float: Float::NAN, repeated_double: [Float::NAN, 1.0])
    assert_equal a, b
    assert_equal a.hash, b.hash
    refute_equal a, @all.new(optional_double: Float::NAN, optional_float: Float::NAN, repeated_double: [Float::NAN, 2.0])
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    assert_equal maps.new(map_int32_double: {1 => Float::NAN}), maps.new(map_int32_double: {1 => Float::NAN})
  end

  def test_dup_and_clone_are_deep
    m = sample
    copy = m.dup
    assert_equal m, copy
    copy.optional_nested_message.bb = 9
    copy.repeated_int32 << 3
    copy.repeated_nested_message.first.bb = 9
    assert_equal 5, m.optional_nested_message.bb
    assert_equal [1, 2], m.repeated_int32
    assert_equal 1, m.repeated_nested_message.first.bb
    clone = m.clone
    clone.optional_nested_message.bb = 8
    assert_equal 5, m.optional_nested_message.bb
  end

  def test_dup_of_frozen_is_unfrozen_and_clone_stays_frozen
    m = sample.freeze
    refute m.dup.frozen?
    refute m.dup.optional_nested_message.frozen?
    m.dup.repeated_int32 << 1
    assert m.clone.frozen?
    assert m.clone.optional_nested_message.frozen?
    refute m.clone(freeze: false).frozen?
    assert sample.clone(freeze: true).frozen?
  end

  def test_freeze_is_deep_and_shareable
    m = sample
    m.repeated_string << +"mutable"
    m.freeze
    assert m.frozen?
    assert m.optional_nested_message.frozen?
    assert m.repeated_int32.frozen?
    assert m.repeated_nested_message.first.frozen?
    assert m.repeated_string.first.frozen?
    assert Ractor.shareable?(m)
    assert_raises(FrozenError) { m.optional_int32 = 2 }
    assert_raises(FrozenError) { m.repeated_int32 << 3 }
    assert_raises(FrozenError) { m.optional_nested_message.bb = 2 }
    assert_raises(FrozenError) { m.clear! }
    assert_raises(FrozenError) { m.merge!(sample) }
    assert_equal [], m.repeated_float, "unset repeated fields of a frozen message read empty"
    assert m.repeated_float.frozen?
    assert_equal m, @all.decode(m.encode)
  end

  def test_inspect
    assert_equal "#<proto2_unittest.TestAllTypes>", @all.new.inspect
    m = @all.new(optional_int32: 1, optional_string: "x", repeated_int32: [1, 2], optional_nested_enum: :BAR)
    assert_equal '#<proto2_unittest.TestAllTypes optional_int32: 1, optional_string: "x", ' \
      "optional_nested_enum: :BAR, repeated_int32: [1, 2]>", m.inspect
    assert_equal "#<proto2_unittest.TestAllTypes optional_nested_message: " \
      "#<proto2_unittest.TestAllTypes.NestedMessage bb: 1>>", @all.new(optional_nested_message: {bb: 1}).inspect
    assert_equal "#<proto3_unittest.TestAllTypes optional_int32: 2>", @all3.new(optional_int32: 2, optional_int64: 0).inspect
    assert_equal m.inspect, m.to_s
  end

  def test_unknown_fields
    bytes = "\xA0\x06\x96\x01\xAA\x06\x02hi".b
    m = @all.decode(bytes)
    assert m.unknown_fields.frozen?
    assert_equal [100, 101], m.unknown_fields.map(&:number)
    first, second = m.unknown_fields
    assert_equal Protostar::Wire::VARINT, first.wire_type
    assert_equal "\x96\x01".b, first.bytes
    assert_equal 150, first.value
    assert_equal "\x02hi".b, second.bytes
    assert_equal "hi", second.value
    assert_equal bytes, m.encode
    assert_equal [], @all.new.unknown_fields
  end

  def test_merge
    a = @all.new(optional_int32: 1, optional_string: "a", repeated_int32: [1], optional_nested_message: {bb: 1},
      oneof_uint32: 3)
    b = @all.new(optional_string: "b", repeated_int32: [2], optional_nested_message: {}, oneof_string: "s",
      optional_foreign_message: {c: 4})
    merged = @all.merge(a, b)
    assert_equal 1, merged.optional_int32
    assert_equal "b", merged.optional_string
    assert_equal [1, 2], merged.repeated_int32
    assert_equal 1, merged.optional_nested_message.bb, "messages merge recursively"
    assert_equal :oneof_string, merged.which_oneof_field
    assert_equal 4, merged.optional_foreign_message.c
    assert_equal [1], a.repeated_int32, "merge leaves its arguments alone"
    assert_equal @all.decode(a.encode + b.encode), merged, "merging equals decoding the concatenation"
    merged.optional_foreign_message.c = 5
    assert_equal 4, b.optional_foreign_message.c, "merge copies messages it takes over"
  end

  def test_merge_maps_and_proto3
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    a = maps.new(map_int32_int32: {1 => 1, 2 => 2})
    b = maps.new(map_int32_int32: {2 => 3, 4 => 4})
    assert_equal({1 => 1, 2 => 3, 4 => 4}, maps.merge(a, b).map_int32_int32)
    p = @all3.new(optional_int32: 5)
    q = @all3.new(optional_int32: 0, optional_string: "q")
    merged = @all3.merge(p, q)
    assert_equal 5, merged.optional_int32, "a zero without presence does not overwrite"
    assert_equal "q", merged.optional_string
  end

  def test_merge_requires_the_same_class
    assert_raises(Protostar::TypeError) { @all.new.merge!(@all3.new) }
  end

  def test_clear
    m = @all.decode(sample.encode + "\xA0\x06\x01".b)
    assert_same m, m.clear!
    assert_equal @all.new, m
    assert_empty m.unknown_fields
    assert_equal "".b, m.encode
  end

  def test_initialized
    required = @unittest["proto2_unittest.TestRequired"]
    refute required.new.initialized?
    assert required.new(a: 1, b: 2, c: 3).initialized?
    foreign = @unittest["proto2_unittest.TestRequiredForeign"]
    assert foreign.new.initialized?
    refute foreign.new(optional_message: {a: 1}).initialized?
    refute foreign.new(repeated_message: [{a: 1, b: 2, c: 3}, {}]).initialized?
    assert foreign.new(repeated_message: [{a: 1, b: 2, c: 3}]).initialized?
    assert_equal "".b, required.new.encode, "required fields are not checked on encode"
  end

  def test_encode_and_class_encode
    m = sample
    assert_equal m.encode, @all.encode(m)
    assert_equal m.encode, m.to_proto
    assert_raises(Protostar::TypeError) { @all.encode(@all3.new) }
  end
end
