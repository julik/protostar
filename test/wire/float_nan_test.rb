# frozen_string_literal: true

require "test_helper"

# A float NaN keeps its sign and payload through decode and encode, as a double does
class FloatNanTest < Minitest::Test
  # quiet NaNs: negative, with a payload, both
  NANS = [0xFFC0_0000, 0x7FC0_0001, 0xFFD2_3456, 0x7FC0_0000].freeze

  def bits(n)
    [n].pack("V")
  end

  def float(n)
    bits(n).unpack1("e")
  end

  def proto3
    CodecFixtures.load("google/protobuf/test_messages_proto3.proto")["protobuf_test_messages.proto3.TestAllTypesProto3"]
  end

  def proto2
    CodecFixtures.load("google/protobuf/test_messages_proto2.proto")["protobuf_test_messages.proto2.TestAllTypesProto2"]
  end

  def test_writer_keeps_the_bits
    NANS.each do |n|
      w = Protostar::Wire::Writer.new
      w.write_float(float(n))
      assert_equal bits(n), w.string, format("%08x", n)
    end
    assert_equal bits(0x7FC0_0000), Protostar::Wire.float_nan(Float::NAN)
    assert_equal bits(0xFFC0_0000), Protostar::Wire.float_nan(-Float::NAN)
  end

  def test_singular_packed_unpacked_and_map_values_round_trip
    NANS.each do |n|
      singular = "\x5D".b + bits(n) # field 11, fixed32
      packed = "\xCA\x02\x08".b + bits(n) + bits(0x3F80_0000) # field 41 packed: NaN, 1.0
      map = "\x92\x04\x07\x08\x01\x15".b + bits(n) # field 66, map<int32, float> {1 => NaN}
      [singular, packed, map].each do |bytes|
        message = proto3.decode(bytes)
        assert_equal bytes, message.encode, format("%08x", n)
        assert_equal bytes, proto3.decode(bytes, frozen: true).encode
      end
      unpacked = "\xCD\x02".b + bits(n) + "\xCD\x02".b + bits(n) # proto2 repeated_float, not packed
      assert_equal unpacked, proto2.decode(unpacked).encode
    end
  end

  def test_assignment_keeps_sign_and_payload
    NANS.each do |n|
      m = proto3.new(optional_float: float(n), repeated_float: [float(n)])
      assert_equal "\x5D".b + bits(n) + "\xCA\x02\x04".b + bits(n), m.encode, format("%08x", n)
    end
    double = [0xFFF8_0000_2000_0000].pack("Q<").unpack1("E") # negative, payload in the float's range
    assert_equal "\x5D".b + bits(0xFFC0_0001), proto3.new(optional_float: double).encode
  end

  def test_builder_keeps_the_bits
    NANS.each do |n|
      bytes = Protostar::Builder.build(proto3) do |pb|
        pb.optional_float float(n)
        pb.repeated_float [float(n), 1.0]
      end
      assert_equal "\x5D".b + bits(n) + "\xCA\x02\x08".b + bits(n) + bits(0x3F80_0000), bytes, format("%08x", n)
    end
  end

  # Reading a signalling NaN into a Ruby Float quiets it (the C conversion
  # does), so it comes back with the quiet bit set; sign and payload stay
  def test_a_signalling_nan_comes_back_quiet
    assert_equal "\x5D".b + bits(0xFFE0_0001), proto3.decode("\x5D".b + bits(0xFFA0_0001)).encode
  end
end
