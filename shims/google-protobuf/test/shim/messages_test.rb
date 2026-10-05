# frozen_string_literal: true

require "test/unit"
require "google/protobuf"
require "google/protobuf/well_known_types"
require "basic_test_pb"
require "basic_test_proto2_pb"
require "service_test_pb"

# What the shim adds over protostar's runtime that Google's own tests and the
# recorded differences do not pin
class MessagesTest < Test::Unit::TestCase
  Pool = Google::Protobuf::DescriptorPool.generated_pool
  M = BasicTest::TestMessage

  def ext(name)
    Pool.lookup(name)
  end

  def test_containers_write_through_and_keep_their_identity
    m = M.new
    list = m.repeated_int32
    list << 1 << 2
    assert_same list, m.repeated_int32
    assert_equal [1, 2], M.decode(M.encode(m)).repeated_int32.to_a
    m.clear_repeated_int32
    refute_same list, m.repeated_int32
    assert_empty m.repeated_int32
    map = BasicTest::MapMessage.new
    entries = map.map_string_msg
    entries["a"] = BasicTest::TestMessage2.new(foo: 1)
    assert_same entries, map.map_string_msg
    assert_equal 1, BasicTest::MapMessage.decode(BasicTest::MapMessage.encode(map)).map_string_msg["a"].foo
  end

  def test_decoded_messages_are_shim_classes_all_the_way_down
    m = M.decode(M.encode(M.new(optional_msg: {foo: 1}, repeated_msg: [{foo: 2}])))
    assert_instance_of BasicTest::TestMessage2, m.optional_msg
    assert_instance_of BasicTest::TestMessage2, m.repeated_msg.first
    assert_kind_of Google::Protobuf::MessageExts, m.repeated_msg.first
    map = BasicTest::MapMessage.decode(BasicTest::MapMessage.encode(BasicTest::MapMessage.new(map_string_msg: {"a" => {foo: 3}})))
    assert_instance_of BasicTest::TestMessage2, map.map_string_msg["a"]
  end

  def test_unknown_numbers_of_closed_enums_stay_in_the_field
    m = BasicTestProto2::TestMessage.decode("\x58\xe7\x07".b) # optional_enum = 999
    assert_equal 999, m.optional_enum
    assert_empty m.unknown_fields
  end

  def test_extensions_on_options_messages
    test_options = ext("service_test_protos.test_options")
    service = Pool.lookup("service_test_protos.TestService")
    assert_equal 8325, test_options.get(service.options).int_option_value
    oneof = BasicTest::TestDeprecatedMessage.descriptor.lookup_oneof("test_deprecated_message_oneof")
    assert_equal "Custom option value", ext("basic_test.test_top_level_option").get(oneof.options)
    assert_equal "Another custom option value", ext("basic_test.TestDeprecatedMessage.test_nested_option").get(oneof.options)
    assert service.options.frozen?
  end

  def test_extensions_set_get_clear_encode_and_json
    message = BasicTestProto2::TestExtensions.new
    int = ext("basic_test_proto2.optional_int32_extension")
    refute int.has?(message)
    int.set(message, 7)
    assert int.has?(message)
    copy = BasicTestProto2::TestExtensions.decode(BasicTestProto2::TestExtensions.encode(message))
    assert_equal 7, int.get(copy)
    assert_equal copy, message
    refute_equal BasicTestProto2::TestExtensions.new, message
    assert_equal({}, message.to_h)
    assert_equal '{"[basic_test_proto2.optional_int32_extension]":7}', message.to_json
    Google::Protobuf.discard_unknown(message)
    assert_equal 7, int.get(message), "discard_unknown keeps extensions"
    int.clear(message)
    refute int.has?(message)
    assert_equal 0, int.get(message)
    assert_raises(Google::Protobuf::TypeError) { int.set(message, "x") }
    assert_raises(Google::Protobuf::TypeError) { int.get(M.new) }
  end

  def test_message_set_items
    set = BasicTestProto2::TestMessageSet.new
    one = ext("basic_test_proto2.TestMessageSetExtension1.message_set_extension")
    one.set(set, one.subtype.msgclass.new(i: 42))
    bytes = BasicTestProto2::TestMessageSet.encode(set)
    assert_equal "\x0B".b, bytes[0], "a MessageSet item group"
    assert_equal 42, one.get(BasicTestProto2::TestMessageSet.decode(bytes)).i
  end

  def test_shallow_dup_and_deep_copy
    m = M.new(optional_msg: {foo: 1}, repeated_int32: [1])
    dup = m.dup
    assert_same m.optional_msg, dup.optional_msg
    dup.repeated_int32 << 2
    assert_equal [1, 2], m.repeated_int32.to_a, "dup shares repeated fields, as the gem's does"
    deep = Google::Protobuf.deep_copy(m)
    refute_same m.optional_msg, deep.optional_msg
    deep.repeated_int32 << 3
    assert_equal [1, 2], m.repeated_int32.to_a
    m.freeze
    assert m.dup.frozen?
    refute Google::Protobuf.deep_copy(m).frozen?
  end

  def test_frozen_messages_hand_out_frozen_containers_and_messages
    m = M.new(repeated_msg: [{foo: 1}], optional_msg: {foo: 2})
    m.freeze
    assert m.repeated_int32.frozen?
    assert_same m.repeated_int32, m.repeated_int32
    assert m.repeated_msg.first.frozen?
    assert m.optional_msg.frozen?
    error = assert_raises(FrozenError) { m.repeated_msg << BasicTest::TestMessage2.new }
    assert_match "can't modify frozen Google::Protobuf::RepeatedField", error.message
  end

  def test_recursion_limits
    deep = BasicTest::Recursive1.new
    node = deep
    101.times do
      child = BasicTest::Recursive2.new
      node.foo = child
      node = BasicTest::Recursive1.new
      child.foo = node
    end
    assert_raises(RuntimeError) { BasicTest::Recursive1.encode(deep) }
    bytes = BasicTest::Recursive1.encode(deep, recursion_limit: 1000)
    assert_raises(Google::Protobuf::ParseError) { BasicTest::Recursive1.decode(bytes) }
    assert_kind_of BasicTest::Recursive1, BasicTest::Recursive1.decode(bytes, recursion_limit: 300)
    cycle = BasicTest::Recursive1.new(foo: BasicTest::Recursive2.new)
    cycle.foo.foo = cycle
    assert_raises(RuntimeError) { BasicTest::Recursive1.encode(cycle) }
  end

  def test_well_known_type_conversions_on_assignment
    m = BasicTest::TimeMessage.new(timestamp: Time.at(10, 5, :nsec), duration: 1.25)
    assert_equal Google::Protobuf::Timestamp.new(seconds: 10, nanos: 5), m.timestamp
    assert_equal Google::Protobuf::Duration.new(seconds: 1, nanos: 250_000_000), m.duration
    assert_raises(Google::Protobuf::TypeError) { m.timestamp = 5 }
  end

  def test_map_entry_descriptors_have_classes
    entry = BasicTest::MapMessage.descriptor.lookup("map_string_msg").subtype
    klass = entry.msgclass
    assert_same klass, entry.msgclass
    assert_same entry, klass.descriptor
    assert_equal({key: "a", value: {foo: 1}}, klass.new(key: "a", value: {foo: 1}).to_h)
  end
end
