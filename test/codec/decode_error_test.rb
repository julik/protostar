# frozen_string_literal: true

require "test_helper"

class DecodeErrorTest < Minitest::Test
  def setup
    @unittest = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @unittest["proto2_unittest.TestAllTypes"]
  end

  def assert_decode_error(bytes, message, offset, klass: @all, **options)
    error = assert_raises(Protostar::DecodeError) { klass.decode(bytes.b, **options) }
    assert_match message, error.message
    assert_equal offset, error.offset, "offset for #{message}"
    assert_match "at byte #{offset}", error.message
    assert_kind_of Protostar::Error, error
  end

  def test_truncated_varint
    assert_decode_error "\x08", "truncated varint", 1
    assert_decode_error "\x08\x96", "truncated varint", 1
    assert_decode_error "\x80", "truncated varint", 0
  end

  def test_varint_over_ten_bytes
    assert_decode_error "\x08" + "\xFF" * 10 + "\x01", "varint longer than 10 bytes", 1
  end

  def test_length_past_the_end
    assert_decode_error "\x72\x05ab", "length 5 runs past the end", 2
    assert_decode_error "\x92\x01\x05\x08", "length 5 runs past the end", 3
  end

  def test_nested_length_past_its_parent
    inner = "\x0A\x09\x08\x01".b
    bytes = "\x92\x01".b + [inner.bytesize].pack("C") + inner + "\x08\x01".b
    assert_decode_error bytes, "runs past the end", 5
  end

  def test_truncated_fixed_values
    assert_decode_error "\x3D\x01\x02", "truncated 32-bit value", 1
    assert_decode_error "\x41\x01\x02\x03\x04\x05\x06\x07", "truncated 64-bit value", 1
  end

  def test_unmatched_end_group
    assert_decode_error "\x08\x01\x84\x01", "unmatched end of group 16", 2
  end

  def test_missing_end_group
    assert_decode_error "\x83\x01\x88\x01\x01", "missing end of group 16", 5
    assert_decode_error "\xA3\x06\x08\x01", "missing end of group 100", 4
  end

  def test_mismatched_end_group
    assert_decode_error "\x83\x01\x88\x01\x01\xF4\x02", "unmatched end of group 46", 5
    assert_decode_error "\xA3\x06\xAC\x06", "end of group 101 does not match group 100", 2
  end

  def test_invalid_wire_types
    assert_decode_error "\x0E\x00", "invalid wire type 6", 0
    assert_decode_error "\x08\x01\x0F", "invalid wire type 7", 2
  end

  def test_field_number_zero
    assert_decode_error "\x00\x01", "field number 0", 0
    assert_decode_error "\x02\x00", "field number 0", 0
  end

  def test_tag_out_of_range
    assert_decode_error "\x80\x80\x80\x80\x10\x00", "tag out of range", 0
  end

  # conformance: Required.*.ProtobufInput.BadTag_OverlongVarint
  def test_tag_longer_than_five_bytes
    overlong = "\x88\x80\x80\x80\x80\x80\x80\x80\x00"
    assert_decode_error "#{overlong}\xd2\x09", "tag longer than 5 bytes", 0
    assert_decode_error "\x08\x01#{overlong}\x01", "tag longer than 5 bytes", 2
    assert_decode_error "\x88\x80\x80\x80\x80\x00\x01", "tag longer than 5 bytes", 0, klass: @unittest["proto2_unittest.TestEmptyMessage"]
    assert_decode_error "\x83\x01\x8c\x80\x80\x80\x80\x00", "tag longer than 5 bytes", 2,
      klass: @unittest["proto2_unittest.TestEmptyMessage"]
    assert_equal 1, @all.decode("\x88\x80\x80\x80\x00\x01".b).optional_int32, "five bytes are fine"
  end

  def test_recursion_limit
    recursive = @unittest["proto2_unittest.TestRecursiveMessage"]
    deep = ->(n) do
      m = recursive.new(i: 1)
      n.times { m = recursive.new(a: m) }
      m
    end
    recursive.decode(deep.call(100).encode)
    error = assert_raises(Protostar::DecodeError) { recursive.decode(deep.call(101).encode) }
    assert_match "recursion limit exceeded", error.message
    assert_equal 0, recursive.decode(deep.call(150).encode, recursion_limit: 150).a.a.i
    assert_raises(Protostar::DecodeError) { recursive.decode(deep.call(3).encode, recursion_limit: 2) }
    recursive.decode(deep.call(2).encode, recursion_limit: 2)
  end

  def test_recursion_limit_counts_unknown_groups
    bytes = ("\xA3\x06" * 101) + ("\xA4\x06" * 101)
    error = assert_raises(Protostar::DecodeError) { @all.decode(bytes.b) }
    assert_match "nested too deep", error.message
    @all.decode((("\xA3\x06" * 50) + ("\xA4\x06" * 50)).b)
  end

  def test_errors_in_map_entries_and_packed_runs
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    assert_decode_error "\x0A\x02\x08", "length 2 runs past the end", 2, klass: maps
    assert_decode_error "\x0A\x02\x0C\x00", "unmatched end of group 1", 2, klass: maps
    assert_decode_error "\xFA\x01\x01\x96", "truncated varint", 3
  end
end
