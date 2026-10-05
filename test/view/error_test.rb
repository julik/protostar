# frozen_string_literal: true

require "test_helper"

# Malformed input: the top level fails when the view is made, a nested
# message when it is first read, and both with decode's message and offset.
class ViewErrorTest < Minitest::Test
  VARINT = Protostar::Wire::VARINT
  LD = Protostar::Wire::LENGTH_DELIMITED

  def setup
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = set["proto2_unittest.TestAllTypes"]
    @packed = set["proto2_unittest.TestPackedTypes"]
    @proto3 = CodecFixtures.load("google/protobuf/unittest_proto3.proto")["proto3_unittest.TestAllTypes"]
  end

  TOP_LEVEL = {
    "truncated varint value" => "\x08\x80".b,
    "truncated tag" => "\x80".b,
    "length past the end" => "\x72\x05abc".b,
    "message length past the end" => "\x92\x01\x05\x08".b,
    "truncated fixed32" => "\x3d\x01\x02".b,
    "truncated fixed64" => "\x41\x01\x02\x03".b,
    "field number 0" => "\x00\x01".b,
    "invalid wire type" => "\x0e\x01".b,
    "unmatched end of group" => "\x08\x01\x0c".b,
    "missing end of group" => "\x83\x01\x88\x01\x01".b,
    "group closed by another group's end" => "\x83\x01\x8c\x02".b,
    "tag out of range" => "\x80\x80\x80\x80\x20".b,
    "varint longer than 10 bytes" => "\x08#{"\xff" * 10}\x01".b,
    "unknown field truncated" => "\xa0\x1f\x80".b,
    "unknown group unterminated" => "\xa3\x1f\x08\x01".b
  }.freeze

  TOP_LEVEL.each do |label, bytes|
    define_method(:"test_top_level_#{label.tr(" '", "__")}") do
      assert_same_error(-> { @all.decode(bytes) }, -> { @all.view(bytes) })
    end
  end

  def test_packed_runs_are_checked_when_the_view_is_made
    fixed = wire.write_tag(@packed.__by_name.fetch(:packed_fixed32).number, LD).write_bytes("\x01\x02\x03".b).string
    assert_same_error(-> { @packed.decode(fixed) }, -> { @packed.view(fixed) })
    varint = wire.write_tag(@packed.__by_name.fetch(:packed_int32).number, LD).write_bytes("\x01\x80".b).string
    assert_same_error(-> { @packed.decode(varint) }, -> { @packed.view(varint) })
  end

  def test_nested_slice_fails_when_first_read
    inner = "\x08\x80".b # bb, truncated
    bytes = wire.write_tag(1, VARINT).write_varint(7)
      .write_tag(@all.__by_name.fetch(:optional_nested_message).number, LD).write_bytes(inner).string
    view = @all.view(bytes)
    assert_equal 7, view.optional_int32
    assert_same_error(-> { @all.decode(bytes) }, -> { view.optional_nested_message })
  end

  def test_repeated_and_map_elements_fail_when_read
    bad = "\x08\x80".b
    bytes = wire.write_tag(@all.__by_name.fetch(:repeated_nested_message).number, LD).write_bytes("\x08\x01".b)
      .write_tag(@all.__by_name.fetch(:repeated_nested_message).number, LD).write_bytes(bad).string
    view = @all.view(bytes)
    assert_equal 2, view.repeated_nested_message.size
    assert_equal 1, view.repeated_nested_message[0].bb
    assert_same_error(-> { @all.decode(bytes) }, -> { view.repeated_nested_message[1] })

    map = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    bytes = wire.write_tag(1, LD).write_bytes("\x08\x01\x10".b).string
    view = map.view(bytes)
    assert_same_error(-> { map.decode(bytes) }, -> { view.map_int32_int32.to_h })
  end

  def test_invalid_utf8_fails_when_the_string_is_read
    bytes = wire.write_tag(@proto3.__by_name.fetch(:optional_string).number, LD).write_bytes("ok\xff".b)
      .write_tag(@proto3.__by_name.fetch(:optional_int32).number, VARINT).write_varint(3).string
    view = @proto3.view(bytes)
    assert_equal 3, view.optional_int32
    assert_same_error(-> { @proto3.decode(bytes) }, -> { view.optional_string })
    # proto2 strings are not validated
    proto2 = wire.write_tag(@all.__by_name.fetch(:optional_string).number, LD).write_bytes("\xff".b).string
    assert_equal "\xff".b, @all.view(proto2).optional_string.b
  end

  def test_recursion_limit
    recursive = CodecFixtures.load("google/protobuf/unittest.proto")["proto2_unittest.TestRecursiveMessage"]
    bytes = recursive.new(a: {a: {a: {i: 1}}}).encode
    view = recursive.view(bytes, recursion_limit: 2)
    assert_equal 0, view.a.a.i
    error = assert_raises(Protostar::DecodeError) { view.a.a.a }
    assert_match(/recursion limit exceeded/, error.message)
    assert_raises(Protostar::DecodeError) { recursive.decode(bytes, recursion_limit: 2) }
    assert_equal 1, recursive.view(bytes, recursion_limit: 3).a.a.a.i
  end

  def test_offset_and_length_are_checked
    assert_raises(ArgumentError) { @all.view("abc", offset: 2, length: 2) }
    assert_raises(ArgumentError) { @all.view("abc", offset: -1) }
    assert_raises(::TypeError) { @all.view(123) }
    assert_raises(NotImplementedError) { Protostar::Message.view("") }
  end

  private

  def assert_same_error(eager, lazy)
    expected = assert_raises(Protostar::DecodeError) { eager.call }
    actual = assert_raises(Protostar::DecodeError) { lazy.call }
    assert_equal expected.message, actual.message
    assert_equal expected.offset, actual.offset
  end

  def wire
    Protostar::Wire::Writer.new
  end
end
