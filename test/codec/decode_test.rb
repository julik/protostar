# frozen_string_literal: true

require "test_helper"

# The decoding rules of the WS3 spec, one by one, on the corpus files it names
class DecodeTest < Minitest::Test
  W = Protostar::Wire

  def setup
    @unittest = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @unittest["proto2_unittest.TestAllTypes"]
    @all3 = CodecFixtures.load("google/protobuf/unittest_proto3.proto")["proto3_unittest.TestAllTypes"]
  end

  def wire
    w = W::Writer.new
    yield w
    w.string
  end

  def test_every_scalar_wire_type
    bytes = wire do |w|
      w.write_tag(1, 0).write_varint(-5)                 # optional_int32
      w.write_tag(5, 0).write_zigzag(-6)                 # optional_sint32
      w.write_tag(7, 5).write_fixed32(7)                 # optional_fixed32
      w.write_tag(8, 1).write_fixed64(8)                 # optional_fixed64
      w.write_tag(9, 5).write_sfixed32(-9)               # optional_sfixed32
      w.write_tag(10, 1).write_sfixed64(-10)             # optional_sfixed64
      w.write_tag(11, 5).write_float(1.5)                # optional_float
      w.write_tag(12, 1).write_double(-2.5)              # optional_double
      w.write_tag(13, 0).write_varint(2)                 # optional_bool, any non-zero
      w.write_tag(14, 2).write_bytes("str")              # optional_string
      w.write_tag(15, 2).write_bytes("\xFF".b)           # optional_bytes
    end
    m = @all.decode(bytes)
    assert_equal [-5, -6, 7, 8, -9, -10, 1.5, -2.5, true, "str", "\xFF".b],
      [m.optional_int32, m.optional_sint32, m.optional_fixed32, m.optional_fixed64, m.optional_sfixed32,
        m.optional_sfixed64, m.optional_float, m.optional_double, m.optional_bool, m.optional_string, m.optional_bytes]
    assert_equal Encoding::UTF_8, m.optional_string.encoding
    assert_equal Encoding::BINARY, m.optional_bytes.encoding
    assert m.optional_string.frozen?
  end

  def test_groups
    bytes = wire do |w|
      w.write_tag(16, 3).write_tag(17, 0).write_varint(1).write_tag(16, 4)
      w.write_tag(46, 3).write_tag(47, 0).write_varint(2).write_tag(46, 4)
      w.write_tag(46, 3).write_tag(46, 4)
    end
    m = @all.decode(bytes)
    assert_equal 1, m.optionalgroup.a
    assert_equal [2, 0], m.repeatedgroup.map(&:a)
    assert_equal bytes, m.encode
  end

  def test_editions_delimited_messages
    set = CodecFixtures.load("google/protobuf/unittest_delimited.proto")
    klass = set["editions_unittest.TestDelimited"]
    m = klass.new(lengthprefixed: {a: 1}, nested: {grouplike: {b: 2}}, notgrouplike: {a: 3}, messageimport: {b: 4})
    bytes = m.encode
    expected = wire do |w|
      w.write_tag(1, 2).write_bytes(wire { |x| x.write_tag(1, 0).write_varint(1) })
      w.write_tag(2, 3).write_tag(3, 3).write_tag(2, 0).write_varint(2).write_tag(3, 4).write_tag(2, 4)
      w.write_tag(4, 3).write_tag(1, 0).write_varint(3).write_tag(4, 4)
      w.write_tag(6, 3).write_tag(2, 0).write_varint(4).write_tag(6, 4)
    end
    assert_equal expected, bytes
    assert_equal m, klass.decode(bytes)
  end

  def test_delimited_field_sent_length_prefixed_is_unknown
    set = CodecFixtures.load("google/protobuf/unittest_delimited.proto")
    klass = set["editions_unittest.TestDelimited"]
    bytes = wire { |w| w.write_tag(3, 2).write_bytes("\x08\x01".b) }
    m = klass.decode(bytes)
    assert_nil m.grouplike
    assert_equal [3], m.unknown_fields.map(&:number)
    assert_equal bytes, m.encode
  end

  def test_unknown_groups_are_skipped_and_kept
    group = wire do |w|
      w.write_tag(200, 3)
      w.write_tag(1, 0).write_varint(1)
      w.write_tag(201, 3).write_tag(2, 2).write_bytes("deep").write_tag(201, 4)
      w.write_tag(200, 4)
    end
    bytes = wire { |w| w.write_tag(1, 0).write_varint(3) } + group
    m = @all.decode(bytes)
    assert_equal 3, m.optional_int32
    field = m.unknown_fields.first
    assert_equal [200, W::START_GROUP], [field.number, field.wire_type]
    assert_equal group.byteslice(2..), field.bytes
    assert_equal bytes, m.encode
  end

  def test_packed_and_expanded_are_both_accepted
    packed = wire { |w| w.write_tag(31, 2).write_bytes(wire { |x| x.write_varint(1).write_varint(-1).write_varint(300) }) }
    expanded = wire { |w| [1, -1, 300].each { |v| w.write_tag(31, 0).write_varint(v) } }
    assert_equal [1, -1, 300], @all.decode(packed).repeated_int32, "packed into an expanded field"
    assert_equal [1, -1, 300], @all3.decode(expanded).repeated_int32, "expanded into a packed field"
    assert_equal [1, -1, 300, 1, -1, 300], @all.decode(packed + expanded).repeated_int32, "mixed runs append"
    assert_equal expanded, @all.decode(packed).encode, "written as the descriptor says"
    assert_equal packed, @all3.decode(expanded).encode
  end

  PACKABLE = %i[TYPE_INT32 TYPE_INT64 TYPE_UINT32 TYPE_UINT64 TYPE_SINT32 TYPE_SINT64 TYPE_FIXED32 TYPE_FIXED64
    TYPE_SFIXED32 TYPE_SFIXED64 TYPE_FLOAT TYPE_DOUBLE TYPE_BOOL TYPE_ENUM].freeze

  # Two proto3 messages with the same fields, one packed and one expanded
  def packed_pair
    fields = ->(packed) do
      PACKABLE.each_with_index.map do |type, i|
        f = {name: "f_#{type.downcase}", number: i + 1, label: :LABEL_REPEATED, type: type, options: {packed: packed}}
        f[:type_name] = ".pk.E" if type == :TYPE_ENUM
        f
      end
    end
    pool = Protostar::Schema::Pool.new
    file = SchemaFixtures.add(pool, {
      name: "packed_pair.proto", package: "pk", syntax: "proto3",
      enum_type: [{name: "E", value: [{name: "Z", number: 0}, {name: "A", number: 1}]}],
      message_type: [{name: "P", field: fields.call(true)}, {name: "U", field: fields.call(false)}]
    })
    types = Protostar::Types::Registry.new.define(file)
    [types.fetch("pk.P"), types.fetch("pk.U")]
  end

  def test_packed_runs_of_every_packable_type
    packed, expanded = packed_pair
    values = {
      f_type_int32: [1, -1], f_type_int64: [2**40, -2], f_type_uint32: [2**32 - 1, 0], f_type_uint64: [2**64 - 1],
      f_type_sint32: [-2**31, 5], f_type_sint64: [-2**63], f_type_fixed32: [7, 8], f_type_fixed64: [9],
      f_type_sfixed32: [-1], f_type_sfixed64: [-2], f_type_float: [1.5, Float::INFINITY], f_type_double: [-0.5],
      f_type_bool: [true, false], f_type_enum: [:A, 99, :Z]
    }
    p = packed.new(values)
    u = expanded.new(values)
    pr = Protostar::Wire::Reader.new(p.encode)
    seen = []
    until pr.eof?
      number, wt = pr.read_tag
      seen << [number, wt]
      pr.skip_field(number, wt)
    end
    assert_equal (1..14).map { |n| [n, 2] }, seen, "one length-delimited run per packed field"
    assert_equal u, expanded.decode(p.encode)
    assert_equal p, packed.decode(u.encode)
    assert_equal p.encode, packed.decode(u.encode).encode
  end

  def test_packed_fixed_run_must_be_whole
    bytes = wire { |w| w.write_tag(37, 2).write_bytes("\x01\x00\x00\x00\x02".b) }
    error = assert_raises(Protostar::DecodeError) { @all.decode(bytes) }
    assert_match "not a multiple of 4", error.message
  end

  def test_empty_packed_run
    bytes = wire { |w| w.write_tag(31, 2).write_varint(0) }
    assert_equal [], @all3.decode(bytes).repeated_int32
    assert_equal "".b, @all3.new(repeated_int32: []).encode, "an empty packed field writes nothing"
  end

  def test_last_scalar_wins_and_messages_merge
    bytes = wire do |w|
      w.write_tag(1, 0).write_varint(1)
      w.write_tag(18, 2).write_bytes(wire { |x| x.write_tag(1, 0).write_varint(5) })
      w.write_tag(1, 0).write_varint(2)
      w.write_tag(14, 2).write_bytes("a")
      w.write_tag(14, 2).write_bytes("b")
      w.write_tag(18, 2).write_bytes("")
      w.write_tag(19, 2).write_bytes(wire { |x| x.write_tag(1, 0).write_varint(6) })
      w.write_tag(16, 3).write_tag(17, 0).write_varint(1).write_tag(16, 4)
      w.write_tag(16, 3).write_tag(16, 4)
    end
    m = @all.decode(bytes)
    assert_equal 2, m.optional_int32
    assert_equal "b", m.optional_string
    assert_equal 5, m.optional_nested_message.bb, "an empty second occurrence merges, keeping bb"
    assert_equal 6, m.optional_foreign_message.c
    assert_equal 1, m.optionalgroup.a, "groups merge too"
  end

  def test_oneof_last_wins_and_same_member_merges
    bytes = wire do |w|
      w.write_tag(111, 0).write_varint(1)
      w.write_tag(113, 2).write_bytes("s")
    end
    m = @all.decode(bytes)
    assert_equal :oneof_string, m.which_oneof_field
    refute m.has_oneof_uint32?
    nested = ->(tag, value) { wire { |w| w.write_tag(112, 2).write_bytes(wire { |x| x.write_tag(tag, 0).write_varint(value) }) } }
    m = @all.decode(nested.call(1, 4) + nested.call(1, 5))
    assert_equal 5, m.oneof_nested_message.bb
    m = @all.decode(wire { |w| w.write_tag(112, 2).write_bytes("\x08\x04".b).write_tag(111, 0).write_varint(1) })
    assert_equal :oneof_uint32, m.which_oneof_field
    assert_nil m.oneof_nested_message
  end

  def test_maps
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    entry = ->(field, body) { wire { |w| w.write_tag(field, 2).write_bytes(body) } }
    bytes = entry.call(1, wire { |w| w.write_tag(1, 0).write_varint(1).write_tag(2, 0).write_varint(10) }) +
      entry.call(1, wire { |w| w.write_tag(2, 0).write_varint(20) }) +                    # missing key
      entry.call(1, wire { |w| w.write_tag(1, 0).write_varint(3) }) +                     # missing value
      entry.call(1, wire { |w| w.write_tag(2, 0).write_varint(11).write_tag(1, 0).write_varint(1) }) + # reversed, overwrites
      entry.call(1, wire { |w| w.write_tag(1, 0).write_varint(4).write_tag(9, 0).write_varint(1) }) +  # unknown inside
      entry.call(17, wire { |w| w.write_tag(1, 0).write_varint(1) }) +                    # message value missing
      entry.call(14, "")                                                                  # both missing
    m = maps.decode(bytes)
    assert_equal({1 => 11, 0 => 20, 3 => 0, 4 => 0}, m.map_int32_int32)
    assert_equal [1], m.map_int32_foreign_message.keys
    assert_equal({}, m.map_int32_foreign_message[1].to_h)
    assert_equal({"" => ""}, m.map_string_string)
    assert_equal [1, 0, 3, 4], m.map_int32_int32.keys, "insertion order is the order first seen"
  end

  def test_open_enums_keep_unknown_numbers
    set = CodecFixtures.load("google/protobuf/unittest_preserve_unknown_enum.proto")
    plus = set["proto3_preserve_unknown_enum_unittest.MyMessagePlusExtra"]
    mine = set["proto3_preserve_unknown_enum_unittest.MyMessage"]
    source = plus.new(e: :E_EXTRA, repeated_e: %i[E_FOO E_EXTRA], repeated_packed_e: %i[E_EXTRA E_BAR],
      repeated_packed_unexpected_e: %i[E_EXTRA], oneof_e_1: :E_EXTRA)
    m = mine.decode(source.encode)
    assert_equal 3, m.e
    assert_equal [:FOO, 3], m.repeated_e
    assert_equal [3, :BAR], m.repeated_packed_e
    assert_equal [:E_EXTRA], m.repeated_packed_unexpected_e, "MyEnumPlusExtra on both sides"
    assert_equal 3, m.oneof_e_1
    assert_empty m.unknown_fields
    assert_equal source, plus.decode(m.encode)
  end

  def test_closed_enums_move_unknown_numbers_to_unknown_fields
    # edition_unittest's file sets enum_type = CLOSED
    set = CodecFixtures.load("google/protobuf/edition_unittest.proto")
    klass = set["edition_unittest.TestAllTypes"]
    bytes = wire do |w|
      w.write_tag(21, 0).write_varint(1)    # optional_nested_enum FOO
      w.write_tag(21, 0).write_varint(77)   # unknown: kept aside, FOO stays
      w.write_tag(51, 0).write_varint(2)    # repeated_nested_enum BAR
      w.write_tag(51, 0).write_varint(78)
      w.write_tag(51, 2).write_bytes(wire { |x| x.write_varint(3).write_varint(79).write_varint(-1) })
    end
    m = klass.decode(bytes)
    assert_equal :FOO, m.optional_nested_enum
    assert_equal %i[BAR BAZ NEG], m.repeated_nested_enum
    assert_equal [[21, 77], [51, 78], [51, 79]], m.unknown_fields.map { |u| [u.number, u.value] }
    assert m.unknown_fields.all? { |u| u.wire_type == W::VARINT }
    again = klass.decode(m.encode)
    assert_equal m, again
    assert_equal m.unknown_fields, again.unknown_fields
  end

  def test_closed_enum_map_value_keeps_the_whole_entry_unknown
    set = CodecFixtures.load("google/protobuf/map_proto2_unittest.proto")
    plus = set["proto2_unittest.TestEnumMapPlusExtra"]
    base = set["proto2_unittest.TestEnumMap"]
    source = plus.new(known_map_field: {1 => :E_PROTO2_MAP_ENUM_BAR}, unknown_map_field: {2 => :E_PROTO2_MAP_ENUM_EXTRA})
    m = base.decode(source.encode)
    assert_equal({1 => :PROTO2_MAP_ENUM_BAR}, m.known_map_field)
    assert_equal({}, m.unknown_map_field)
    assert_equal [[102, W::LENGTH_DELIMITED]], m.unknown_fields.map { |u| [u.number, u.wire_type] }
    assert_equal source, plus.decode(m.encode), "the entry survives a pass through the older schema"
  end

  def test_utf8_validation
    bad = wire { |w| w.write_tag(14, 2).write_bytes("\xC3\x28".b) }
    error = assert_raises(Protostar::DecodeError) { @all3.decode(bad) }
    assert_match "invalid UTF-8 in proto3_unittest.TestAllTypes.optional_string", error.message
    assert_equal 2, error.offset, "the offset of the string's bytes"
    m = @all.decode(bad)
    assert_equal "\xC3\x28".b, m.optional_string.b, "unittest.proto turns utf8_validation off"
    refute m.optional_string.valid_encoding?
    bytes = wire { |w| w.write_tag(15, 2).write_bytes("\xC3\x28".b) }
    assert_equal "\xC3\x28".b, @all3.decode(bytes).optional_bytes, "bytes are never validated"
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    bad_key = wire { |w| w.write_tag(14, 2).write_bytes(wire { |x| x.write_tag(1, 2).write_bytes("\xFF".b) }) }
    assert_raises(Protostar::DecodeError) { maps.decode(bad_key) }
  end

  def test_wire_type_mismatch_is_an_unknown_field
    bytes = wire { |w| w.write_tag(1, 2).write_bytes("x").write_tag(14, 0).write_varint(1) }
    m = @all.decode(bytes)
    refute m.has_optional_int32?
    refute m.has_optional_string?
    assert_equal [[1, 2], [14, 0]], m.unknown_fields.map { |u| [u.number, u.wire_type] }
    assert_equal bytes, m.encode
  end

  def test_unknown_fields_at_every_level_in_order_after_known_fields
    inner = wire { |w| w.write_tag(1, 0).write_varint(1).write_tag(99, 5).write_fixed32(5) }
    bytes = wire do |w|
      w.write_tag(500, 1).write_fixed64(1)
      w.write_tag(18, 2).write_bytes(inner)
      w.write_tag(400, 0).write_varint(2)
      w.write_tag(1, 0).write_varint(3)
    end
    m = @all.decode(bytes)
    assert_equal [500, 400], m.unknown_fields.map(&:number)
    assert_equal [99], m.optional_nested_message.unknown_fields.map(&:number)
    expected = wire do |w|
      w.write_tag(1, 0).write_varint(3)
      w.write_tag(18, 2).write_bytes(inner)
      w.write_tag(500, 1).write_fixed64(1)
      w.write_tag(400, 0).write_varint(2)
    end
    assert_equal expected, m.encode
  end

  def test_message_set_items_survive_as_unknown_groups
    set = CodecFixtures.load("google/protobuf/unittest_mset.proto")
    raw = set["proto2_unittest.RawMessageSet"]
    container = set["proto2_unittest.TestMessageSetContainer"]
    ext = set["proto2_unittest.TestMessageSetExtension1"]
    items = raw.new(item: [{type_id: 1_545_008, message: ext.new(i: 123).encode}, {type_id: 4, message: "\x08\x01".b}])
    bytes = wire { |w| w.write_tag(1, 2).write_bytes(items.encode) }
    m = container.decode(bytes)
    assert_equal [1, 1], m.message_set.unknown_fields.map(&:number)
    assert_equal bytes, m.encode
    assert_equal items, raw.decode(m.message_set.encode)
  end

  def test_decode_never_mutates_its_input
    bytes = @all.new(optional_string: "héllo", repeated_bytes: ["x"]).encode.force_encoding(Encoding::UTF_8).freeze
    m = @all.decode(bytes)
    assert_equal "héllo", m.optional_string
    assert_equal Encoding::UTF_8, bytes.encoding
    unfrozen = +bytes.b
    before = unfrozen.dup
    @all.decode(unfrozen)
    assert_equal before, unfrozen
  end

  def test_decode_accepts_io_buffer
    skip "no IO::Buffer" unless defined?(IO::Buffer)
    bytes = @all.new(optional_int32: 7, optional_string: "s").encode
    assert_equal 7, @all.decode(IO::Buffer.for(bytes)).optional_int32
  end

  def test_frozen_decode
    source = @all.new(optional_nested_message: {bb: 1}, repeated_nested_message: [{bb: 2}], repeated_int32: [1],
      optional_string: "s", optionalgroup: {a: 1})
    bytes = source.encode + "\xA0\x06\x01".b
    m = @all.decode(bytes, frozen: true)
    assert m.frozen?
    assert m.optional_nested_message.frozen?
    assert m.repeated_nested_message.frozen?
    assert m.repeated_nested_message.first.frozen?
    assert m.unknown_fields.frozen?
    assert Ractor.shareable?(m)
    assert_equal source, m
    twice = @all.decode(bytes + source.encode, frozen: true)
    assert twice.optional_nested_message.frozen?, "a merged repeat stays frozen"
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    mm = maps.decode(maps.new(map_int32_foreign_message: {1 => {c: 1}}).encode, frozen: true)
    assert Ractor.shareable?(mm)
  end
end
