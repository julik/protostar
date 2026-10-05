# frozen_string_literal: true

require "test_helper"

class ReaderWriterTest < Minitest::Test
  W = Protostar::Wire

  def test_fixed32_and_fixed64
    w = W::Writer.new
    w.write_fixed32(0).write_fixed32(2**32 - 1).write_fixed64(2**64 - 1).write_sfixed32(-2**31).write_sfixed64(-2**63)
    assert_equal "\x00\x00\x00\x00\xFF\xFF\xFF\xFF".b + ("\xFF" * 8).b + "\x00\x00\x00\x80".b +
      "\x00\x00\x00\x00\x00\x00\x00\x80".b, w.string
    r = W::Reader.new(w.string)
    assert_equal [0, 2**32 - 1, 2**64 - 1, -2**31, -2**63],
      [r.read_fixed32, r.read_fixed32, r.read_fixed64, r.read_sfixed32, r.read_sfixed64]
    assert r.eof?
  end

  def test_floats_and_doubles
    values = [0.0, -0.0, 1.5, Float::INFINITY, -Float::INFINITY, Float::NAN, 5e-324, 2.2250738585072014e-308,
      1.7976931348623157e+308]
    w = W::Writer.new
    values.each { |v| w.write_double(v) }
    r = W::Reader.new(w.string)
    values.each { |v| assert_same_float v, r.read_double }

    singles = [0.0, -0.0, 1.5, Float::INFINITY, -Float::INFINITY, Float::NAN, 1.401298464324817e-45,
      1.1754942106924411e-38, 3.4028234663852886e+38]
    w = W::Writer.new
    singles.each { |v| w.write_float(v) }
    assert_equal 4 * singles.size, w.string.bytesize
    r = W::Reader.new(w.string)
    singles.each { |v| assert_same_float v, r.read_float }
  end

  def test_nan_bits_survive_a_double_round_trip
    quiet = "\x01\x00\x00\x00\x00\x00\xF8\x7F".b
    v = W::Reader.new(quiet).read_double
    assert v.nan?
    assert_equal quiet, W::Writer.new.write_double(v).string
  end

  def test_bytes_and_strings_of_any_encoding
    w = W::Writer.new
    w.write_bytes("é").write_bytes("\xFF".b).write_bytes("")
    assert_equal "\x02\xC3\xA9\x01\xFF\x00".b, w.string
    assert_equal Encoding::BINARY, w.string.encoding
    r = W::Reader.new(w.string)
    assert_equal "é".b, r.read_bytes
    assert_equal "\xFF".b, r.read_bytes
    assert_equal "", r.read_bytes
  end

  def test_reader_does_not_mutate_or_copy_its_input
    input = "\x08\x96\x01".encode(Encoding::UTF_8).force_encoding(Encoding::UTF_8)
    r = W::Reader.new(input)
    assert_equal [1, 0], r.read_tag
    assert_equal 150, r.read_varint
    assert_equal Encoding::UTF_8, input.encoding
    assert_same input, r.buffer
  end

  def test_reader_accepts_io_buffer
    skip "no IO::Buffer" unless defined?(IO::Buffer)
    buffer = IO::Buffer.for("\x08\x96\x01".b)
    r = W::Reader.new(buffer)
    assert_instance_of W::IOSource, r.buffer
    assert_same buffer, r.buffer.buffer, "the buffer is read in place, not copied"
    assert_equal [1, 0], r.read_tag
    assert_equal 150, r.read_varint
    r = W::Reader.new(IO::Buffer.for([1.5].pack("E") + "\x02hi".b))
    assert_equal 1.5, r.read_double
    assert_equal "hi", r.read_bytes
  end

  def test_reader_accepts_any_source_with_string_byte_methods
    source = Struct.new(:string) do
      def getbyte(i) = string.getbyte(i)

      def byteslice(o, n) = string.byteslice(o, n)

      def unpack1(f, offset:) = string.unpack1(f, offset: offset)

      def bytesize = string.bytesize
    end.new("\x08\x96\x01\x15\x01\x00\x00\x00".b)
    r = W::Reader.new(source)
    assert_same source, r.buffer
    assert_equal [1, 0], r.read_tag
    assert_equal 150, r.read_varint
    assert_equal [2, 5], r.read_tag
    assert_equal 1, r.read_fixed32
    assert_raises(::TypeError) { W::Reader.new(Object.new) }
    assert_raises(::TypeError) { W::Reader.new([1, 2]) }
  end

  def test_limits
    r = W::Reader.new("\x03abcdef".b)
    old = r.push_limit(r.read_varint)
    assert_equal "abc", r.read_raw(3)
    assert r.eof?
    assert_raises(Protostar::DecodeError) { r.read_varint }
    r.pop_limit(old)
    assert_equal "def", r.read_raw(3)
    r = W::Reader.new("\x05ab".b)
    error = assert_raises(Protostar::DecodeError) { r.push_limit(r.read_varint) }
    assert_equal 1, error.offset
  end

  def test_skip_field_for_every_wire_type
    w = W::Writer.new
    w.write_varint(300)
    w.write_fixed64(1)
    w.write_bytes("abc")
    w.write_tag(5, W::VARINT).write_varint(1).write_tag(6, W::START_GROUP).write_tag(6, W::END_GROUP)
    w.write_tag(4, W::END_GROUP)
    w.write_fixed32(1)
    r = W::Reader.new(w.string)
    r.skip_field(1, W::VARINT)
    r.skip_field(1, W::FIXED64)
    r.skip_field(1, W::LENGTH_DELIMITED)
    r.skip_field(4, W::START_GROUP)
    r.skip_field(1, W::FIXED32)
    assert r.eof?
  end

  def test_writer_to_io_flushes
    io = StringIO.new(+"")
    w = W::Writer.new(io)
    w.write_bytes("x" * (W::Writer::FLUSH_AT + 10))
    assert_operator io.string.bytesize, :>=, W::Writer::FLUSH_AT
    w.write_varint(1).flush
    assert_equal W::Writer::FLUSH_AT + 10 + 3 + 1, io.string.bytesize
  end

  def test_writer_appends_to_a_given_string
    s = +"ab"
    W::Writer.new(s).write_varint(1)
    assert_equal "ab\x01".b, s
  end

  private

  def assert_same_float(expected, actual)
    if expected.nan?
      assert actual.nan?
    else
      assert_equal expected, actual
      assert_equal (1.0 / expected).negative?, (1.0 / actual).negative?, "sign of zero" if expected.zero?
    end
  end
end
