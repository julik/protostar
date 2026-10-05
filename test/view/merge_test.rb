# frozen_string_literal: true

require "test_helper"

# Inputs the encoder never writes but decoders must merge: each case is
# built on the wire by hand and read the same through a view as by decode.
class ViewMergeTest < Minitest::Test
  VARINT = Protostar::Wire::VARINT
  FIXED32 = Protostar::Wire::FIXED32
  LD = Protostar::Wire::LENGTH_DELIMITED
  START_GROUP = Protostar::Wire::START_GROUP
  END_GROUP = Protostar::Wire::END_GROUP

  def setup
    @unittest = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @unittest["proto2_unittest.TestAllTypes"]
    @packed = @unittest["proto2_unittest.TestPackedTypes"]
  end

  def test_last_scalar_wins
    w = wire
    w.write_tag(n(@all, :optional_int32), VARINT).write_varint(1)
    w.write_tag(n(@all, :optional_string), LD).write_bytes("first")
    w.write_tag(n(@all, :optional_int32), VARINT).write_varint(2)
    w.write_tag(n(@all, :optional_string), LD).write_bytes("second")
    w.write_tag(n(@all, :optional_fixed32), FIXED32).write_fixed32(5)
    w.write_tag(n(@all, :optional_fixed32), FIXED32).write_fixed32(6)
    view = assert_same_as_decode(@all, w.string)
    assert_equal 2, view.optional_int32
    assert_equal "second", view.optional_string
    assert_equal 6, view.optional_fixed32
  end

  def test_split_repeated_runs_concatenate
    w = wire
    w.write_tag(n(@all, :repeated_int32), VARINT).write_varint(1)
    w.write_tag(n(@all, :repeated_string), LD).write_bytes("a")
    w.write_tag(n(@all, :optional_int32), VARINT).write_varint(9)
    w.write_tag(n(@all, :repeated_int32), VARINT).write_varint(2)
    w.write_tag(n(@all, :repeated_string), LD).write_bytes("b")
    view = assert_same_as_decode(@all, w.string)
    assert_equal [1, 2], view.repeated_int32.to_a
    assert_equal %w[a b], view.repeated_string.to_a
  end

  def test_packed_and_expanded_mix
    w = wire
    w.write_tag(n(@all, :repeated_int32), VARINT).write_varint(1)
    w.write_tag(n(@all, :repeated_int32), LD).write_bytes(varints(2, 300, 2**31 - 1))
    w.write_tag(n(@all, :repeated_int32), VARINT).write_varint(-4)
    w.write_tag(n(@all, :repeated_fixed32), LD).write_bytes([7, 8].pack("V*"))
    w.write_tag(n(@all, :repeated_fixed32), FIXED32).write_fixed32(9)
    w.write_tag(n(@all, :repeated_int32), LD).write_bytes("")
    view = assert_same_as_decode(@all, w.string)
    assert_equal [1, 2, 300, 2**31 - 1, -4], view.repeated_int32.to_a
    assert_equal [7, 8, 9], view.repeated_fixed32.to_a

    w = wire
    w.write_tag(n(@packed, :packed_int32), VARINT).write_varint(5)
    w.write_tag(n(@packed, :packed_int32), LD).write_bytes(varints(6, 7))
    w.write_tag(n(@packed, :packed_double), Protostar::Wire::FIXED64).write_double(1.5)
    w.write_tag(n(@packed, :packed_double), LD).write_bytes([2.5, -0.0].pack("E*"))
    view = assert_same_as_decode(@packed, w.string)
    assert_equal [5, 6, 7], view.packed_int32.to_a
    assert_equal [1.5, 2.5, -0.0], view.packed_double.to_a
  end

  def test_sub_message_in_pieces_is_one_view
    w = wire
    w.write_tag(n(@all, :optional_foreign_message), LD).write_bytes(wire.write_tag(1, VARINT).write_varint(1).string)
    w.write_tag(n(@all, :optional_int32), VARINT).write_varint(3)
    w.write_tag(n(@all, :optional_foreign_message), LD).write_bytes(wire.write_tag(2, VARINT).write_varint(2).string)
    w.write_tag(n(@all, :optional_foreign_message), LD).write_bytes(wire.write_tag(1, VARINT).write_varint(4).write_tag(900, VARINT).write_varint(1).string)
    view = assert_same_as_decode(@all, w.string)
    sub = view.optional_foreign_message
    assert_equal 4, sub.c
    assert_equal 2, sub.d
    assert_equal 3, sub.__segments.size
    assert_equal [900], sub.unknown_fields.map(&:number)
    assert_equal sub.to_message.encode, @all.decode(w.string).optional_foreign_message.encode
    assert_equal sub.__segments.sum { |_, length| length }, sub.encode.bytesize
  end

  def test_group_in_pieces
    group = n(@all, :optionalgroup)
    w = wire
    w.write_tag(group, START_GROUP).write_tag(17, VARINT).write_varint(1).write_tag(group, END_GROUP)
    w.write_tag(n(@all, :repeatedgroup), START_GROUP).write_tag(47, VARINT).write_varint(5).write_tag(n(@all, :repeatedgroup), END_GROUP)
    w.write_tag(group, START_GROUP).write_tag(800, VARINT).write_varint(2).write_tag(group, END_GROUP)
    w.write_tag(n(@all, :repeatedgroup), START_GROUP).write_tag(n(@all, :repeatedgroup), END_GROUP)
    view = assert_same_as_decode(@all, w.string)
    assert_equal 1, view.optionalgroup.a
    assert_equal [800], view.optionalgroup.unknown_fields.map(&:number)
    assert_equal [5, 0], view.repeatedgroup.map(&:a)
  end

  def test_group_end_tag_written_long
    group = n(@all, :optionalgroup)
    end_tag = (group << 3) | END_GROUP
    w = wire
    w.write_tag(group, START_GROUP).write_tag(17, VARINT).write_varint(8)
    w.write_raw([(end_tag & 0x7F) | 0x80, (end_tag >> 7) | 0x80, 0].pack("C*"))
    w.write_tag(n(@all, :optional_int32), VARINT).write_varint(1)
    view = assert_same_as_decode(@all, w.string)
    assert_equal 8, view.optionalgroup.a
    assert_equal 1, view.optional_int32
  end

  def test_duplicate_map_keys_keep_the_last_entry
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")
    klass = maps["proto2_unittest.TestMap"]
    entry = ->(key, value) { wire.write_tag(1, VARINT).write_varint(key).write_tag(2, VARINT).write_varint(value).string }
    message_entry = ->(key, c) { wire.write_tag(1, VARINT).write_varint(key).write_tag(2, LD).write_bytes(wire.write_tag(1, VARINT).write_varint(c).string).string }
    w = wire
    w.write_tag(n(klass, :map_int32_int32), LD).write_bytes(entry.call(1, 10))
    w.write_tag(n(klass, :map_int32_int32), LD).write_bytes(entry.call(2, 20))
    w.write_tag(n(klass, :map_int32_int32), LD).write_bytes(entry.call(1, 11))
    w.write_tag(n(klass, :map_int32_int32), LD).write_bytes("") # key and value both default
    w.write_tag(n(klass, :map_int32_int32), LD).write_bytes(wire.write_tag(2, VARINT).write_varint(5).write_tag(1, VARINT).write_varint(3).write_tag(7, VARINT).write_varint(1).string)
    w.write_tag(n(klass, :map_int32_foreign_message), LD).write_bytes(message_entry.call(1, 1))
    w.write_tag(n(klass, :map_int32_foreign_message), LD).write_bytes(message_entry.call(1, 2))
    w.write_tag(n(klass, :map_int32_foreign_message), LD).write_bytes(wire.write_tag(1, VARINT).write_varint(9).string)
    view = assert_same_as_decode(klass, w.string)
    assert_equal({1 => 11, 2 => 20, 0 => 0, 3 => 5}, view.map_int32_int32.to_h)
    assert_equal [1, 2, 0, 3], view.map_int32_int32.keys
    assert_equal 2, view.map_int32_foreign_message[1].c
    assert_equal 0, view.map_int32_foreign_message[9].c
    assert_nil view.map_int32_foreign_message[5]
    assert view.map_int32_foreign_message.key?(9)
  end

  def test_map_message_value_in_pieces_within_one_entry
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")
    klass = maps["proto2_unittest.TestMap"]
    entry = wire.write_tag(1, VARINT).write_varint(4)
      .write_tag(2, LD).write_bytes(wire.write_tag(1, VARINT).write_varint(1).string)
      .write_tag(2, LD).write_bytes(wire.write_tag(2, VARINT).write_varint(2).string).string
    w = wire.write_tag(n(klass, :map_int32_foreign_message), LD).write_bytes(entry)
    view = assert_same_as_decode(klass, w.string)
    assert_equal [1, 2], [view.map_int32_foreign_message[4].c, view.map_int32_foreign_message[4].d]
  end

  def test_oneof_last_member_wins
    w = wire
    w.write_tag(n(@all, :oneof_nested_message), LD).write_bytes(wire.write_tag(1, VARINT).write_varint(1).string)
    w.write_tag(n(@all, :oneof_uint32), VARINT).write_varint(7)
    w.write_tag(n(@all, :oneof_string), LD).write_bytes("s")
    view = assert_same_as_decode(@all, w.string)
    assert_equal :oneof_string, view.which_oneof_field
    assert_equal "s", view.oneof_string
    assert_equal 0, view.oneof_uint32
    assert_nil view.oneof_nested_message

    # a message member set again after another member starts afresh
    w.write_tag(n(@all, :oneof_nested_message), LD).write_bytes(wire.write_tag(800, VARINT).write_varint(2).string)
    w.write_tag(n(@all, :oneof_nested_message), LD).write_bytes("")
    view = assert_same_as_decode(@all, w.string)
    assert_equal :oneof_nested_message, view.which_oneof_field
    assert_equal 2, view.oneof_nested_message.__segments.size
    refute view.oneof_nested_message.has_bb?
    assert_equal [800], view.oneof_nested_message.unknown_fields.map(&:number)
  end

  def test_closed_enum_unknown_numbers_become_unknown_fields
    w = wire
    w.write_tag(n(@all, :optional_nested_enum), VARINT).write_varint(2)
    w.write_tag(n(@all, :optional_nested_enum), VARINT).write_varint(99)
    w.write_tag(n(@all, :repeated_nested_enum), VARINT).write_varint(98)
    w.write_tag(n(@all, :repeated_nested_enum), VARINT).write_varint(3)
    w.write_tag(n(@all, :repeated_nested_enum), LD).write_bytes(varints(1, 97, -1, 2))
    w.write_tag(900, VARINT).write_varint(1)
    view = assert_same_as_decode(@all, w.string)
    assert_equal :BAR, view.optional_nested_enum
    assert_equal %i[BAZ FOO NEG BAR], view.repeated_nested_enum.to_a
    assert_equal [n(@all, :optional_nested_enum)] + [n(@all, :repeated_nested_enum)] * 2 + [900], view.unknown_fields.map(&:number)
  end

  def test_closed_enum_in_a_map_moves_the_entry
    maps = CodecFixtures.load("google/protobuf/map_proto2_unittest.proto")
    plus = maps["proto2_unittest.TestEnumMapPlusExtra"]
    base = maps["proto2_unittest.TestEnumMap"]
    bytes = plus.new(known_map_field: {1 => :E_PROTO2_MAP_ENUM_FOO}, unknown_map_field: {1 => :E_PROTO2_MAP_ENUM_EXTRA, 2 => :E_PROTO2_MAP_ENUM_FOO}).encode
    view = assert_same_as_decode(base, bytes)
    assert_equal({2 => :PROTO2_MAP_ENUM_FOO}, view.unknown_map_field.to_h)
    assert_equal 1, view.unknown_fields.size
  end

  def test_open_enum_keeps_unknown_numbers
    proto3 = CodecFixtures.load("google/protobuf/unittest_proto3.proto")
    klass = proto3["proto3_unittest.TestAllTypes"]
    w = wire
    w.write_tag(n(klass, :optional_nested_enum), VARINT).write_varint(77)
    w.write_tag(n(klass, :repeated_nested_enum), LD).write_bytes(varints(1, 78))
    w.write_tag(n(klass, :optional_int32), VARINT).write_varint(5)
    w.write_tag(n(klass, :optional_int32), VARINT).write_varint(0)
    view = assert_same_as_decode(klass, w.string)
    assert_equal 77, view.optional_nested_enum
    assert_equal [:FOO, 78], view.repeated_nested_enum.to_a
    assert_equal 0, view.optional_int32
    refute view.to_h.key?(:optional_int32)
  end

  def test_wire_type_mismatch_is_unknown
    w = wire
    w.write_tag(n(@all, :optional_int32), FIXED32).write_fixed32(1)
    w.write_tag(n(@all, :optional_string), VARINT).write_varint(1)
    w.write_tag(n(@all, :optional_nested_message), VARINT).write_varint(1)
    w.write_tag(n(@all, :optional_int64), START_GROUP).write_tag(1, VARINT).write_varint(1).write_tag(n(@all, :optional_int64), END_GROUP)
    view = assert_same_as_decode(@all, w.string)
    refute view.has_optional_int32?
    refute view.has_optional_nested_message?
    assert_equal 4, view.unknown_fields.size
  end

  def test_long_tags_and_values
    w = wire
    tag = (n(@all, :optional_int32) << 3) | VARINT
    w.write_raw([tag | 0x80, 0x80, 0x80, 0x00].pack("C*")).write_varint(-1)
    w.write_tag(n(@all, :optional_uint64), VARINT).write_varint(2**64 - 1)
    w.write_tag(n(@all, :optional_sint64), VARINT).write_varint(2**64 - 1)
    w.write_tag(n(@all, :optional_bool), VARINT).write_raw("\x80\x80\x01".b)
    view = assert_same_as_decode(@all, w.string)
    assert_equal(-1, view.optional_int32)
    assert_equal 2**64 - 1, view.optional_uint64
    assert_equal(-2**63, view.optional_sint64)
    assert_equal true, view.optional_bool
  end

  def test_unset_fields_read_their_defaults
    defaults = @unittest["proto2_unittest.TestExtremeDefaultValues"]
    view = assert_same_as_decode(defaults, "")
    message = defaults.new
    defaults.__fields.each do |info|
      next if info.repeated || info.map || info.message?
      assert_equal ViewSupport.plain(message.__get(info)), ViewSupport.plain(view[info.name]), info.name
    end
    assert_equal({}, view.to_h)
    assert_empty @all.view("").repeated_nested_message
    assert_empty @all.view("").repeated_int32
  end

  private

  def assert_same_as_decode(klass, bytes)
    decoded = klass.decode(bytes)
    view = klass.view(bytes)
    assert_equal ViewSupport.plain(decoded.__to_h), ViewSupport.plain(view.to_h)
    assert_equal decoded, view.to_message
    assert_equal decoded.unknown_fields, view.unknown_fields
    assert_equal view, decoded
    view
  end

  def n(klass, name)
    klass.__by_name.fetch(name).number
  end

  def wire
    Protostar::Wire::Writer.new
  end

  def varints(*values)
    values.each_with_object(wire) { |v, w| w.write_varint(v) }.string
  end
end
