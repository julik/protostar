# frozen_string_literal: true

require "test_helper"

class EncodeTest < Minitest::Test
  W = Protostar::Wire

  def setup
    @unittest = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @unittest["proto2_unittest.TestAllTypes"]
  end

  def wire
    w = W::Writer.new
    yield w
    w.string
  end

  def test_fields_in_ascending_number_order
    klass = @unittest["proto2_unittest.TestFieldOrderings"]
    m = klass.new(my_float: 1.0, my_string: "s", my_int: 2, optional_nested_message: {bb: 1, oo: 3})
    numbers = []
    r = W::Reader.new(m.encode)
    until r.eof?
      number, wt = r.read_tag
      numbers << number
      r.skip_field(number, wt)
    end
    assert_equal numbers.sort, numbers
    assert_equal [1, 11, 101, 200], numbers
  end

  def test_negative_int32_and_enum_take_ten_bytes
    m = @all.new(optional_int32: -1, optional_nested_enum: :NEG)
    expected = wire do |w|
      w.write_tag(1, 0).write_raw("\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x01".b)
      w.write_tag(21, 0).write_raw("\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x01".b)
    end
    assert_equal expected, m.encode
    assert_equal 23, m.encode.bytesize
  end

  def test_float_specials_round_trip
    [Float::NAN, Float::INFINITY, -Float::INFINITY, -0.0, 5e-324].each do |v|
      m = @all.new(optional_double: v, optional_float: v)
      d = @all.decode(m.encode)
      if v.nan?
        assert d.optional_double.nan?
        assert d.optional_float.nan?
      else
        assert_equal [v].pack("E"), [d.optional_double].pack("E")
        assert_equal [v].pack("e"), [d.optional_float].pack("e")
      end
    end
  end

  def test_negative_zero_is_written_without_presence
    all3 = CodecFixtures.load("google/protobuf/unittest_proto3.proto")["proto3_unittest.TestAllTypes"]
    assert_equal "".b, all3.new(optional_double: 0.0).encode
    bytes = all3.new(optional_double: -0.0).encode
    assert_equal wire { |w| w.write_tag(12, 1).write_double(-0.0) }, bytes, "as protoc, which compares bits"
  end

  def test_maps_write_key_then_value_in_insertion_order
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    m = maps.new(map_int32_int32: {2 => 0, 1 => 5})
    expected = wire do |w|
      w.write_tag(1, 2).write_bytes(wire { |x| x.write_tag(1, 0).write_varint(2).write_tag(2, 0).write_varint(0) })
      w.write_tag(1, 2).write_bytes(wire { |x| x.write_tag(1, 0).write_varint(1).write_tag(2, 0).write_varint(5) })
    end
    assert_equal expected, m.encode
  end

  def test_presence_fields_set_to_default_are_written
    assert_equal "\x08\x00".b, @all.new(optional_int32: 0).encode
    assert_equal "\x72\x00".b, @all.new(optional_string: "").encode
    assert_equal "\x92\x01\x00".b, @all.new(optional_nested_message: {}).encode
  end

  def test_deterministic
    m = RandomMessage.build(@all, random: Random.new(7), depth: 3, fill: 1.0)
    assert_equal m.encode, m.encode
    assert_equal m.encode, m.dup.encode
    assert_equal m.encode, @all.decode(m.encode).encode
  end

  def test_large_message_with_deep_nesting_sizes_once_per_message
    nested = @unittest["proto2_unittest.NestedTestAllTypes"]
    m = nested.new
    cursor = m
    50.times do
      cursor.payload = {repeated_string: ["x" * 200]}
      cursor.child = {}
      cursor = cursor.child
    end
    bytes = m.encode
    assert_equal m, nested.decode(bytes)
    assert_operator bytes.bytesize, :>, 50 * 200
  end

  def test_encode_to_io
    m = @all.new(optional_string: "x" * 100_000, repeated_int32: [1, 2])
    io = StringIO.new(+"".b)
    assert_same io, m.encode_to(io)
    assert_equal m.encode, io.string
  end

  def test_encode_to_a_pipe
    m = @all.new(optional_bytes: Random.new(1).bytes(200_000), repeated_nested_message: [{bb: 1}])
    reader, writer = IO.pipe
    collected = Thread.new { reader.read }
    m.encode_to(writer)
    writer.close
    assert_equal m.encode, collected.value.b
    reader.close
  end

  def test_output_is_binary
    m = @all.new(optional_string: "日本")
    assert_equal Encoding::BINARY, m.encode.encoding
    assert_equal Encoding::BINARY, m.encode_delimited.encoding
  end
end
