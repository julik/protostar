# frozen_string_literal: true

require "test_helper"
require "stringio"

class DelimitedTest < Minitest::Test
  def setup
    @all = CodecFixtures.load("google/protobuf/unittest.proto")["proto2_unittest.TestAllTypes"]
    @messages = [
      @all.new(optional_int32: 1),
      @all.new,
      @all.new(optional_string: "x" * 300, repeated_nested_message: [{bb: 2}]),
      RandomMessage.build(@all, random: Random.new(3), depth: 2)
    ]
  end

  def test_encode_delimited_returns_length_then_message
    m = @messages[2]
    bytes = m.encode_delimited
    body = m.encode
    assert_equal Protostar::Wire.varint(body.bytesize) + body, bytes
    assert_equal "\x00".b, @all.new.encode_delimited
  end

  def test_stream_round_trip_over_string_io
    io = StringIO.new(+"".b)
    @messages.each { |m| assert_same io, m.encode_delimited(io) }
    io.rewind
    read = []
    while (m = @all.decode_delimited(io))
      read << m
    end
    assert_equal @messages, read
    assert io.eof?
  end

  def test_decode_delimited_from_a_string_reads_the_first_message
    bytes = @messages[0].encode_delimited + @messages[2].encode_delimited
    assert_equal @messages[0], @all.decode_delimited(bytes)
  end

  def test_decode_delimited_passes_options
    m = @all.decode_delimited(@messages[2].encode_delimited, frozen: true)
    assert m.frozen?
  end

  def test_stream_over_a_pipe
    reader, writer = IO.pipe
    producer = Thread.new do
      @messages.each { |m| m.encode_delimited(writer) }
      writer.close
    end
    read = []
    while (m = @all.decode_delimited(reader))
      read << m
    end
    producer.join
    reader.close
    assert_equal @messages, read
  end

  def test_truncated_streams
    whole = @messages[2].encode_delimited
    assert_raises(Protostar::DecodeError) { @all.decode_delimited(StringIO.new(whole.byteslice(0, 10))) }
    assert_raises(Protostar::DecodeError) { @all.decode_delimited(StringIO.new(whole.byteslice(0, 1))) }
    assert_raises(Protostar::DecodeError) { @all.decode_delimited(whole.byteslice(0, 10)) }
    assert_nil @all.decode_delimited(StringIO.new(+""))
  end
end
