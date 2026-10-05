# frozen_string_literal: true

require "test_helper"

class VarintTest < Minitest::Test
  W = Protostar::Wire

  CASES = {
    0 => "\x00",
    1 => "\x01",
    127 => "\x7F",
    128 => "\x80\x01",
    150 => "\x96\x01",
    300 => "\xAC\x02",
    16_383 => "\xFF\x7F",
    16_384 => "\x80\x80\x01",
    2**32 - 1 => "\xFF\xFF\xFF\xFF\x0F",
    2**63 - 1 => "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x7F",
    2**64 - 1 => "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x01"
  }.transform_values(&:b).freeze

  def test_encodes_and_decodes_edges
    CASES.each do |value, bytes|
      assert_equal bytes, W.varint(value), "encoding #{value}"
      assert_equal bytes.bytesize, W.varint_size(value)
      r = W::Reader.new(bytes)
      assert_equal value, r.read_varint, "decoding #{value}"
      assert r.eof?
    end
  end

  def test_negative_int32_and_int64_take_ten_bytes
    minus_one = "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x01".b
    assert_equal minus_one, W.varint(-1)
    assert_equal 10, W.varint_size(-1)
    assert_equal(-1, W::Reader.new(minus_one).read_int32)
    assert_equal(-1, W::Reader.new(minus_one).read_int64)

    int32_min = W.varint(-2**31)
    assert_equal 10, int32_min.bytesize
    assert_equal "\x80\x80\x80\x80\xF8\xFF\xFF\xFF\xFF\x01".b, int32_min
    assert_equal(-2**31, W::Reader.new(int32_min).read_int32)

    int64_min = W.varint(-2**63)
    assert_equal "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01".b, int64_min
    assert_equal(-2**63, W::Reader.new(int64_min).read_int64)
  end

  def test_int32_from_a_wider_varint_is_truncated_as_protoc_does
    assert_equal(-1, W::Reader.new(W.varint(2**32 - 1)).read_int32)
    assert_equal 1, W::Reader.new(W.varint(2**32 + 1)).read_int32
    assert_equal 5, W::Reader.new(W.varint(2**32 + 5)).read_uint32
  end

  def test_overlong_tenth_byte_is_truncated_to_64_bits
    bytes = "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x7F".b
    assert_equal 2**64 - 1, W::Reader.new(bytes).read_varint
  end

  def test_non_minimal_encoding_reads
    assert_equal 1, W::Reader.new("\x81\x80\x80\x00".b).read_varint
  end

  def test_zigzag_32_bit_extremes
    {0 => 0, -1 => 1, 1 => 2, -2 => 3, 2**31 - 1 => 2**32 - 2, -2**31 => 2**32 - 1}.each do |signed, unsigned|
      assert_equal unsigned, W.zigzag(signed), "zigzag(#{signed})"
      assert_equal signed, W.unzigzag(unsigned)
      assert_equal signed, W::Reader.new(W.varint(unsigned)).read_sint32
    end
  end

  def test_zigzag_64_bit_extremes
    {2**63 - 1 => 2**64 - 2, -2**63 => 2**64 - 1, -3 => 5}.each do |signed, unsigned|
      assert_equal unsigned, W.zigzag(signed)
      assert_equal signed, W.unzigzag(unsigned)
      assert_equal signed, W::Reader.new(W.varint(unsigned)).read_sint64
      assert_equal W.varint(unsigned), W::Writer.new.write_zigzag(signed).string
    end
  end

  def test_tags_for_every_wire_type
    [W::VARINT, W::FIXED64, W::LENGTH_DELIMITED, W::START_GROUP, W::END_GROUP, W::FIXED32].each do |wt|
      assert_equal (8 | wt).chr.b, W.tag_bytes(1, wt)
      max = W.tag_bytes(536_870_911, wt)
      assert_equal 5, max.bytesize
      assert_equal (536_870_911 << 3) | wt, W::Reader.new(max).read_varint
      next if wt == W::END_GROUP
      assert_equal [536_870_911, wt], W::Reader.new(max).read_tag
      assert_equal [1, wt], W::Reader.new(W.tag_bytes(1, wt)).read_tag
    end
    assert_equal "\xF8\xFF\xFF\xFF\x0F".b, W.tag_bytes(536_870_911, W::VARINT)
  end
end
