# frozen_string_literal: true

require "test_helper"

# Types::Registry.new(open_enums: true), which the google-protobuf shim uses:
# every enum behaves as open, as in google-protobuf's Ruby gem
class OpenEnumsTest < Minitest::Test
  def setup
    pool, _file = SchemaFixtures.cached("google/protobuf/unittest.proto")
    @closed = Protostar::Types::Registry.new
    @open = Protostar::Types::Registry.new(open_enums: true)
    pool.files.each do |f|
      @closed.define(f)
      @open.define(f)
    end
  end

  def all_types(registry)
    registry.find("proto2_unittest.TestAllTypes")
  end

  def test_closed_by_default_moves_unknown_numbers_to_unknown_fields
    bytes = "\xA8\x01\x63".b # optional_nested_enum (21) = 99
    message = all_types(@closed).decode(bytes)
    refute message.has_optional_nested_enum?
    assert_equal [21], message.unknown_fields.map(&:number)
    assert_raises(Protostar::TypeError) { all_types(@closed).new(optional_nested_enum: 99) }
  end

  def test_open_keeps_unknown_numbers_in_singular_repeated_and_packed_fields
    klass = all_types(@open)
    message = klass.decode("\xA8\x01\x63".b)
    assert_equal 99, message.optional_nested_enum
    assert_empty message.unknown_fields
    assert_equal [:FOO, 99], klass.decode("\x98\x03\x01\x98\x03\x63".b).repeated_nested_enum
    packed = @open.find("proto2_unittest.TestPackedTypes")
    assert_equal [:FOREIGN_FOO, 99], packed.decode(packed.new(packed_enum: [:FOREIGN_FOO, 99]).encode).packed_enum
    assert_equal 99, klass.new(optional_nested_enum: 99).optional_nested_enum
    assert_equal "\xA8\x01\x63".b, klass.new(optional_nested_enum: 99).encode
  end

  def test_open_keeps_map_entries_with_unknown_closed_enum_values
    pool, _file = SchemaFixtures.cached("google/protobuf/map_unittest.proto")
    registry = Protostar::Types::Registry.new(open_enums: true)
    pool.files.each { |f| registry.define(f) }
    klass = registry.find("proto2_unittest.TestMap")
    field = klass.descriptor.fields_by_name.fetch("map_int32_enum")
    entry = "\x08\x01\x10\x63".b # key 1, value 99
    bytes = Protostar::Wire.tag_bytes(field.number, Protostar::Wire::LENGTH_DELIMITED) + Protostar::Wire.varint(entry.bytesize) + entry
    message = klass.decode(bytes)
    assert_equal({1 => 99}, message.map_int32_enum)
    assert_empty message.unknown_fields
  end
end
