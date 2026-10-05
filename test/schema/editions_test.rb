# frozen_string_literal: true

require "test_helper"

class EditionsTest < Minitest::Test
  def test_edition_unittest
    pool, file = SchemaFixtures.cached("google/protobuf/edition_unittest.proto")
    assert_equal :editions, file.syntax
    assert_equal :EDITION_2026, file.edition
    assert_equal ["google/protobuf/cpp_features.proto"], file.option_dependencies
    assert_equal :EXPLICIT, file.features.field_presence
    assert_equal :CLOSED, file.features.enum_type
    assert_equal :PACKED, file.features.repeated_field_encoding
    assert_equal :VERIFY, file.features.utf8_validation
    assert_equal :STYLE2026, file.features.enforce_naming_style

    m = pool.find_message("edition_unittest.TestAllTypes")
    assert m.field("optional_int32").presence?
    assert m.field("repeated_int32").packed?
    assert m.field("optional_string").utf8_validation?
    assert pool.find_enum("edition_unittest.TestAllTypes.NestedEnum").closed?

    group = m.field("optionalgroup")
    assert_equal :group, group.type
    assert_equal :TYPE_MESSAGE, group.to_h[:type]
    assert_equal :repeated, m.field("repeatedgroup").label
    assert_equal :group, m.field("repeatedgroup").type

    required = pool.find_message("edition_unittest.TestRequiredEnum").field("required_enum")
    assert required.required?
    assert_equal :LABEL_OPTIONAL, required.to_h[:label]
    assert_equal :FOREIGN_FOO, required.default
  end

  def test_delimited_message_encoding
    pool, = SchemaFixtures.cached("google/protobuf/unittest_delimited.proto")
    m = pool.find_message("editions_unittest.TestDelimited")
    refute m.field("lengthprefixed").delimited?
    assert_equal :message, m.field("lengthprefixed").type
    %w[nested grouplike notgrouplike notgrouplikescope messageimport].each do |name|
      assert_equal :group, m.field(name).type, name
      assert m.field(name).delimited?, name
    end

    {1004 => :message, 1000 => :group, 1001 => :group, 1002 => :group, 1003 => :group}.each do |number, type|
      assert_equal type, pool.find_extension(m, number).type, "extension #{number}"
    end
  end

  def test_file_level_delimited_spares_maps
    pool, file = SchemaFixtures.cached("conformance/test_protos/test_messages_edition2023.proto")
    assert_equal :DELIMITED, file.features.message_encoding
    m = pool.find_message("protobuf_test_messages.editions.TestAllTypesEdition2023")
    assert_equal :group, m.field("groupliketype").type, "inherits DELIMITED from the file"
    assert_equal :message, m.field("optional_nested_message").type, "overrides with LENGTH_PREFIXED"
    map = m.field("map_string_nested_message")
    assert_equal :message, map.type, "a map field stays length-prefixed"
    assert map.map?
    assert_equal :message, map.map_value.type, "so does the value of a map entry"
    assert_equal :DELIMITED, map.map_value.features.message_encoding
  end

  def test_feature_overrides_on_fields
    pool, = SchemaFixtures.cached("google/protobuf/unittest.proto")
    packed = pool.find_message("proto2_unittest.TestPackedTypes")
    assert_equal :PACKED, packed.field("packed_int32").features.repeated_field_encoding
    assert_equal :EXPANDED, packed.features.repeated_field_encoding
  end
end
