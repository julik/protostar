# frozen_string_literal: true

require "test_helper"

# proto3: implicit presence, packed by default, open enums, UTF-8 checked,
# synthetic oneofs for `optional`, maps
class Proto3Test < Minitest::Test
  def test_unittest_proto3
    pool, file = SchemaFixtures.cached("google/protobuf/unittest_proto3.proto")
    assert_equal :proto3, file.syntax
    assert_nil file.edition
    assert_equal "proto3", file.to_h[:syntax]
    m = pool.find_message("proto3_unittest.TestAllTypes")

    scalar = m.field("optional_int32")
    refute scalar.presence?
    assert_equal :IMPLICIT, scalar.features.field_presence
    assert m.field("optional_nested_message").presence?, "message fields always have presence"
    assert m.field("oneof_uint32").presence?, "oneof members always have presence"

    assert m.field("repeated_int32").packed?, "proto3 packs by default"
    refute pool.find_message("proto3_unittest.TestUnpackedTypes").field("repeated_int32").packed?
    assert pool.find_message("proto3_unittest.TestPackedTypes").field("packed_enum").packed?

    assert m.field("optional_string").utf8_validation?
    refute m.field("optional_bytes").utf8_validation?

    enum = pool.find_enum("proto3_unittest.TestAllTypes.NestedEnum")
    refute enum.closed?
    assert enum.open?
    assert_equal :ZERO, m.field("optional_nested_enum").default
  end

  def test_proto3_optional
    pool, = SchemaFixtures.cached("google/protobuf/unittest_proto3_optional.proto")
    m = pool.find_message("proto2_unittest.TestProto3Optional")
    field = m.field("optional_int32")
    assert field.proto3_optional?
    assert field.presence?
    assert_equal :EXPLICIT, field.features.field_presence
    assert_equal :optional, field.label

    oneof = field.oneof
    assert_equal "_optional_int32", oneof.name
    assert oneof.synthetic?
    assert_equal [field], oneof.fields
    assert_nil field.real_oneof
    assert_empty m.real_oneofs
    assert_equal m.fields.count(&:proto3_optional?), m.oneofs.size
    assert_equal true, field.to_h[:proto3_optional]

    singular = m.field("singular_int32")
    refute singular.proto3_optional?
    refute singular.presence?
    refute singular.to_h.key?(:proto3_optional)
  end

  def test_maps
    pool, = SchemaFixtures.cached("google/protobuf/map_unittest.proto")
    m = pool.find_message("proto2_unittest.TestMap")
    map = m.field("map_int32_int32")
    assert map.map?
    assert map.repeated?
    refute map.packed?
    refute map.presence?
    entry = map.message_type
    assert entry.map_entry?
    assert_equal "proto2_unittest.TestMap.MapInt32Int32Entry", entry.full_name
    assert_same m, entry.containing_message
    assert_includes m.nested_messages, entry
    assert_equal :int32, map.map_key.type
    assert_equal "key", map.map_key.name
    assert_equal :int32, map.map_value.type

    message_map = m.field("map_int32_foreign_message")
    assert_equal "proto2_unittest.ForeignMessage", message_map.map_value.message_type.full_name
    assert message_map.map_value.presence?
    refute message_map.map_key.presence?, "proto3 map keys have implicit presence"

    enum_map = m.field("map_int32_enum")
    assert_equal :enum, enum_map.map_value.type

    refute pool.find_message("proto2_unittest.TestMap").field(1).message_type.message_set_wire_format?
    assert_nil m.field(1).map_key.map_key
  end
end
