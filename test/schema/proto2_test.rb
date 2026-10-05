# frozen_string_literal: true

require "test_helper"

# proto2: explicit presence, expanded by default, closed enums, groups,
# required, and custom options declared as extensions of descriptor.proto
class Proto2Test < Minitest::Test
  def messages
    SchemaFixtures.cached("google/protobuf/test_messages_proto2.proto")
  end

  def test_file_has_no_syntax_key
    _, file = messages
    assert_equal :proto2, file.syntax
    refute file.to_h.key?(:syntax)
    assert_equal Protostar::Schema::Features::EDITIONS[:EDITION_PROTO2], file.edition_number
  end

  def test_presence_and_packing
    pool, = messages
    m = pool.find_message("protobuf_test_messages.proto2.TestAllTypesProto2")
    assert m.field("optional_int32").presence?
    refute m.field("repeated_int32").packed?, "proto2 expands by default"
    assert m.field("packed_int32").packed?, "[packed = true]"
    assert_equal :PACKED, m.field("packed_int32").features.repeated_field_encoding
    refute m.field("unpacked_int32").packed?, "[packed = false]"
    assert m.field("packed_nested_enum").packed?
    refute m.field("optional_string").utf8_validation?
    assert pool.find_enum("protobuf_test_messages.proto2.TestAllTypesProto2.NestedEnum").closed?
  end

  def test_groups
    pool, = messages
    data = pool.find_message("protobuf_test_messages.proto2.TestAllTypesProto2").field("data")
    assert_equal :group, data.type
    assert data.delimited?
    assert_equal :DELIMITED, data.features.message_encoding
    assert_equal "protobuf_test_messages.proto2.TestAllTypesProto2.Data", data.type_name
    assert_equal :TYPE_GROUP, data.to_h[:type]
    assert_equal "data", data.json_name
  end

  def test_proto2_map_keys_have_presence
    pool, = messages
    map = pool.find_message("protobuf_test_messages.proto2.TestAllTypesProto2").field("map_int32_int32")
    assert map.map?
    assert map.map_key.presence?
  end

  def test_required
    pool, = SchemaFixtures.cached("ruby/tests/basic_test_proto2.proto")
    field = pool.files.flat_map(&:all_messages).flat_map(&:fields).find(&:required?)
    refute_nil field, "basic_test_proto2.proto has required fields"
    assert_equal :LEGACY_REQUIRED, field.features.field_presence
    assert_equal :LABEL_REQUIRED, field.to_h[:label]
  end

  def test_custom_option_extensions
    pool, file = SchemaFixtures.cached("google/protobuf/unittest_custom_options.proto")
    ext = pool.find_extension("google.protobuf.MessageOptions", 7_739_036)
    assert_equal "proto2_unittest.message_opt1", ext.full_name
    assert_equal :int32, ext.type
    assert_equal "google/protobuf/descriptor.proto", ext.extendee.file.name
    assert_equal :fixed64, pool.find_extension("google.protobuf.FieldOptions", 7_740_936).type
    method_opt = pool.find_extension("google.protobuf.MethodOptions", 7_890_860)
    assert_equal :enum, method_opt.type
    assert_equal "proto2_unittest.MethodOpt1", method_opt.enum_type.full_name
    assert_includes pool.extensions_of("google.protobuf.MessageOptions").map(&:name), "message_opt1"
    assert_operator file.all_extensions.size, :>, 30
  end

  def test_services
    pool, file = SchemaFixtures.cached("google/protobuf/unittest_custom_options.proto")
    service = pool.find_service("proto2_unittest.TestServiceWithCustomOptions")
    assert_same service, file.services.first
    assert_equal ["Foo"], service.rpcs.map(&:name)
    foo = service.rpc(:Foo)
    assert_same foo, service.rpc(foo.name)
    assert_equal "proto2_unittest.TestServiceWithCustomOptions.Foo", foo.full_name
    assert_equal "proto2_unittest.CustomOptionFooRequest", foo.input_type.full_name
    assert_equal "proto2_unittest.CustomOptionFooResponse", foo.output_type.full_name
    assert_same service, foo.service
    refute foo.client_streaming?
    refute foo.server_streaming?
    assert_same foo, pool.find_symbol(foo.full_name)
  end

  def test_streaming_methods
    pool, = SchemaFixtures.cached("ruby/tests/service_test.proto")
    methods = pool.files.last.services.flat_map(&:rpcs)
    assert methods.any?(&:client_streaming?)
    assert methods.any?(&:server_streaming?)
    streaming = methods.find(&:client_streaming?)
    assert_equal true, streaming.to_h[:client_streaming]
  end

  def test_declared_but_empty_options_survive
    pool, = SchemaFixtures.cached("google/protobuf/unittest_custom_options.proto")
    m = pool.find_message("proto2_unittest.TestMessageWithCustomOptions")
    map_field = m.field("map_field")
    assert map_field.options.empty?
    assert_equal({}, map_field.to_h[:options])
    refute m.field("oneof_field").to_h.key?(:options)
    assert map_field.options.declared?
    refute m.field("oneof_field").options.declared?
    assert m.options.key?(:message_set_wire_format)
    assert_equal false, m.options[:message_set_wire_format]
    refute m.message_set_wire_format?
  end

  def test_message_set
    pool, = SchemaFixtures.cached("google/protobuf/unittest_mset_wire_format.proto")
    set = pool.files.flat_map(&:all_messages).find(&:message_set_wire_format?)
    refute_nil set
    assert_operator set.extension_ranges.size, :>, 0
  end
end
