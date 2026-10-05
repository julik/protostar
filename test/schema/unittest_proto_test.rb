# frozen_string_literal: true

require "test_helper"

# google/protobuf/unittest.proto: edition 2023 with file-level CLOSED enums,
# EXPANDED repeated fields and no UTF-8 validation
class UnittestProtoTest < Minitest::Test
  def setup
    @pool, @file = SchemaFixtures.cached("google/protobuf/unittest.proto")
  end

  def all_types
    @pool.find_message("proto2_unittest.TestAllTypes")
  end

  def test_file
    assert_equal "proto2_unittest", @file.package
    assert_equal :editions, @file.syntax
    assert_equal :EDITION_2023, @file.edition
    assert_equal ["google/protobuf/unittest_import.proto"], @file.dependencies
    assert_equal "UnittestProto", @file.options[:java_outer_classname]
    assert_same all_types, @file.find_message("proto2_unittest.TestAllTypes")
    assert_same all_types, @file.find_symbol("proto2_unittest.TestAllTypes")
    assert_nil @file.find_message("proto2_unittest.ForeignEnum")
  end

  def test_scalar_fields
    f = all_types.field(1)
    assert_equal "optional_int32", f.name
    assert_equal "proto2_unittest.TestAllTypes.optional_int32", f.full_name
    assert_equal :int32, f.type
    assert_equal :optional, f.label
    assert_equal "optionalInt32", f.json_name
    assert_same f, all_types.field("optional_int32")
    assert_same f, all_types.field(:optional_int32)
    assert_same f, all_types.fields_by_json_name["optionalInt32"]
    assert_same all_types, f.containing_message
    assert_same @file, f.file
    assert_equal 0, f.index
    assert f.presence?
    assert f.scalar?
    refute f.repeated?
    assert_equal 0, f.wire_type
    assert_nil f.type_name

    {2 => [:int64, 0], 7 => [:fixed32, 5], 8 => [:fixed64, 1], 11 => [:float, 5], 12 => [:double, 1],
     13 => [:bool, 0], 14 => [:string, 2], 15 => [:bytes, 2]}.each do |number, (type, wire_type)|
      assert_equal type, all_types.field(number).type
      assert_equal wire_type, all_types.field(number).wire_type
    end
  end

  def test_message_and_enum_fields_link_to_their_types
    nested = all_types.field("optional_nested_message")
    assert_equal :message, nested.type
    assert_equal "proto2_unittest.TestAllTypes.NestedMessage", nested.type_name
    assert_same @pool.find_message("proto2_unittest.TestAllTypes.NestedMessage"), nested.message_type
    refute nested.scalar?

    import = all_types.field("optional_import_message")
    assert_equal "google/protobuf/unittest_import.proto", import.message_type.file.name

    nested_enum = all_types.field("optional_nested_enum")
    assert_equal :enum, nested_enum.type
    assert_same @pool.find_enum("proto2_unittest.TestAllTypes.NestedEnum"), nested_enum.enum_type
    assert nested_enum.scalar?
  end

  def test_public_import_makes_types_visible
    field = all_types.field("optional_public_import_message")
    assert_equal "proto2_unittest_import.PublicImportMessage", field.type_name
    assert_equal "google/protobuf/unittest_import_public.proto", field.message_type.file.name
    assert_includes @file.visible_files.map(&:name), "google/protobuf/unittest_import_public.proto"
  end

  def test_delimited_message_is_a_group
    group = all_types.field("optionalgroup")
    assert_equal :group, group.type
    assert group.delimited?
    assert_equal 3, group.wire_type
    assert_equal "OptionalGroup", group.message_type.name
    assert_equal :TYPE_MESSAGE, group.to_h[:type]
    refute all_types.field("optional_nested_message").delimited?
  end

  def test_repeated_fields_follow_the_file_expanded_encoding
    repeated = all_types.field("repeated_int32")
    assert repeated.repeated?
    assert repeated.packable?
    refute repeated.packed?
    refute repeated.presence?
    refute all_types.field("repeated_string").packable?

    packed = @pool.find_message("proto2_unittest.TestPackedTypes").field("packed_int32")
    assert packed.packed?
    assert_equal :PACKED, packed.features.repeated_field_encoding
    refute @pool.find_message("proto2_unittest.TestUnpackedTypes").field("unpacked_int32").packed?
  end

  def test_oneof
    oneof = all_types.oneofs.first
    assert_equal "oneof_field", oneof.name
    assert_equal "proto2_unittest.TestAllTypes.oneof_field", oneof.full_name
    refute oneof.synthetic?
    assert_equal [oneof], all_types.real_oneofs
    assert_equal %w[oneof_uint32 oneof_nested_message oneof_string oneof_bytes oneof_cord oneof_string_piece
      oneof_lazy_nested_message], oneof.fields.map(&:name)
    member = all_types.field("oneof_uint32")
    assert_same oneof, member.oneof
    assert_same oneof, member.real_oneof
    assert member.presence?
    assert_includes all_types.fields, member
  end

  def test_closed_enum_and_value_full_names
    enum = @pool.find_enum("proto2_unittest.TestAllTypes.NestedEnum")
    assert enum.closed?
    assert_equal %w[FOO BAR BAZ NEG], enum.values.map(&:name)
    assert_equal "proto2_unittest.TestAllTypes.FOO", enum.value(:FOO).full_name
    assert_equal(-1, enum.value("NEG").number)
    assert_equal "NEG", enum.value(-1).name
    assert_same enum, enum.value(1).enum
    assert_same all_types, enum.containing_message

    foreign = @pool.find_enum("proto2_unittest.ForeignEnum")
    assert_equal "proto2_unittest.FOREIGN_FOO", foreign.value(4).full_name
    assert_same foreign.value(4), @pool.find_symbol("proto2_unittest.FOREIGN_FOO")
    assert_nil @pool.find_symbol("proto2_unittest.ForeignEnum.FOREIGN_FOO")
  end

  def test_enum_aliases_keep_the_first_value
    enum = @pool.find_enum("proto2_unittest.TestEnumWithDupValue")
    assert enum.allow_alias?
    assert_equal "FOO1", enum.value(1).name
    assert_equal 1, enum.value(:FOO2).number
    assert_equal 5, enum.values.size
  end

  def test_required_by_feature
    required = @pool.find_message("proto2_unittest.TestRequired")
    a = required.field("a")
    assert a.required?
    assert_equal :required, a.label
    assert_equal :LEGACY_REQUIRED, a.features.field_presence
    assert_equal :LABEL_OPTIONAL, a.to_h[:label]
    refute required.field("dummy2").required?
  end

  def test_declared_defaults
    m = all_types
    assert_equal 41, m.field("default_int32").default_value
    assert_equal 42, m.field("default_int64").default_value
    assert_equal(-45, m.field("default_sint32").default_value)
    assert_equal 51.5, m.field("default_float").default_value
    assert_equal 52e3, m.field("default_double").default_value
    assert_equal true, m.field("default_bool").default_value
    assert_equal "hello", m.field("default_string").default_value
    assert_equal Encoding::UTF_8, m.field("default_string").default_value.encoding
    assert_equal "world".b, m.field("default_bytes").default_value
    assert_equal Encoding::BINARY, m.field("default_bytes").default_value.encoding
    assert_equal :BAR, m.field("default_nested_enum").default_value
    assert_equal :FOREIGN_BAR, m.field("default_foreign_enum").default_value
    assert_equal :IMPORT_BAR, m.field("default_import_enum").default_value
    assert_equal "BAR", m.field("default_nested_enum").to_h[:default_value]
  end

  def test_implicit_defaults
    m = all_types
    assert_nil m.field("optional_int32").default_value
    assert_equal 0, m.field("optional_int32").default
    assert_equal 0.0, m.field("optional_float").default
    assert_equal false, m.field("optional_bool").default
    assert_equal "", m.field("optional_string").default
    assert_equal Encoding::BINARY, m.field("optional_bytes").default.encoding
    assert_equal :FOO, m.field("optional_nested_enum").default
    assert_nil m.field("optional_nested_message").default
    assert_equal 0, m.field("repeated_int32").default
  end

  def test_extreme_defaults
    m = @pool.find_message("proto2_unittest.TestExtremeDefaultValues")
    assert_equal "\0\x01\a\b\f\n\r\t\v\\'\"\xFE".b, m.field("escaped_bytes").default_value
    assert_equal 0xFFFFFFFF, m.field("large_uint32").default_value
    assert_equal 0xFFFFFFFFFFFFFFFF, m.field("large_uint64").default_value
    assert_equal(-0x7FFFFFFF, m.field("small_int32").default_value)
    assert_equal(-0x8000000000000000, m.field("really_small_int64").default_value)
    assert_equal "ሴ", m.field("utf8_string").default_value
    assert_equal 2e8, m.field("large_float").default_value
    assert_equal Float::INFINITY, m.field("inf_double").default_value
    assert_equal(-Float::INFINITY, m.field("neg_inf_double").default_value)
    assert m.field("nan_double").default_value.nan?
    assert_equal Float::INFINITY, m.field("inf_float").default_value
    assert m.field("nan_float").default_value.nan?
    assert_equal "hel\0lo", m.field("string_with_zero").default_value
    assert_equal "wor\0ld".b, m.field("bytes_with_zero").default_value
    assert_equal "? ? ?? ?? ??? ??/ ??-", m.field("cpp_trigraph").default_value
  end

  def test_float_defaults_hold_the_single_precision_value
    small = @pool.find_message("proto2_unittest.TestExtremeDefaultValues").field("small_negative_float")
    assert_equal [-8e-28].pack("e").unpack1("e"), small.default_value
    refute_equal(-8e-28, small.default_value)
    assert_equal "-8e-28", small.to_h[:default_value]
  end

  def test_extensions
    ext = @pool.find_extension("proto2_unittest.TestAllExtensions", 1)
    assert_equal "optional_int32_extension", ext.name
    assert_equal "proto2_unittest.optional_int32_extension", ext.full_name
    assert ext.extension?
    assert ext.presence?
    assert_nil ext.containing_message
    extendee = @pool.find_message("proto2_unittest.TestAllExtensions")
    assert_same extendee, ext.extendee
    assert_same ext, @pool.find_extension(extendee, 1)
    assert_includes @file.extensions, ext
    assert_same ext, @file.find_extension("proto2_unittest.optional_int32_extension")
    assert extendee.extension_number?(1)
    assert_equal [1..536_870_911], extendee.extension_ranges

    scoped = @pool.find_extension("proto2_unittest.TestAllExtensions", 1002)
    holder = @pool.find_message("proto2_unittest.TestNestedExtension")
    assert_equal "proto2_unittest.TestNestedExtension.test", scoped.full_name
    assert_same holder, scoped.containing_message
    assert_includes holder.extensions, scoped
    refute_includes holder.fields, scoped
    assert_equal "test", scoped.default_value
    assert_includes @file.all_extensions, scoped

    numbers = @pool.extensions_of(extendee).map(&:number)
    assert_equal numbers.sort, numbers
    assert_includes numbers, 1002
  end

  def test_group_extension_in_nested_scope
    ext = @pool.find_extension("proto2_unittest.TestGroupExtension", 16)
    assert_equal :group, ext.type
    assert_equal "proto2_unittest.TestNestedExtension.OptionalGroup_extension", ext.type_name
  end

  def test_all_messages_is_depth_first_in_declaration_order
    names = @file.all_messages.map(&:full_name)
    assert_equal names.uniq, names
    assert_operator names.index("proto2_unittest.TestAllTypes"), :<, names.index("proto2_unittest.TestAllTypes.NestedMessage")
    assert_operator names.index("proto2_unittest.TestAllTypes.NestedMessage"), :<, names.index("proto2_unittest.ForeignMessage")
    assert_equal @file.all_messages.size, @file.symbols.values.count { |s| s.is_a?(Protostar::Schema::Message) }
  end

  def test_utf8_validation_off
    refute all_types.field("optional_string").utf8_validation?
    assert_equal :NONE, all_types.field("optional_string").features.utf8_validation
  end

  def test_reserved
    m = @pool.find_message("proto2_unittest.TestReservedFields")
    assert_equal [2..2, 15..15, 9..11], m.reserved_ranges
    assert_equal %w[bar baz], m.reserved_names
  end
end
