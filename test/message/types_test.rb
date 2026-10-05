# frozen_string_literal: true

require "test_helper"

class TypesTest < Minitest::Test
  def test_define_returns_every_message_and_enum_of_the_file
    pool, file = SchemaFixtures.load("google/protobuf/unittest_import.proto")
    registry = Protostar::Types::Registry.new
    pool.files.each { |f| registry.define(f) unless f == file }
    types = registry.define(file)
    assert types.frozen?
    expected = (file.all_messages.reject(&:map_entry?) + file.all_enums).map(&:full_name).sort
    assert_equal expected, types.keys.sort
    message = types.fetch("proto2_unittest_import.ImportMessage")
    assert_operator message, :<, Protostar::Message
    assert_same file.find_message("proto2_unittest_import.ImportMessage"), message.descriptor
    assert_same message, registry.find("proto2_unittest_import.ImportMessage")
    assert_same types, registry.define(file), "defining the same file again returns the same types"
  end

  def test_map_entries_get_no_class
    set = CodecFixtures.load("google/protobuf/map_unittest.proto")
    refute set.types.key?("proto2_unittest.TestMap.MapInt32Int32Entry")
  end

  def test_missing_dependency_names_the_file
    pool, file = SchemaFixtures.load("google/protobuf/unittest.proto")
    registry = Protostar::Types::Registry.new
    error = assert_raises(Protostar::Error) { registry.define(file) }
    assert_match "google/protobuf/unittest_import.proto", error.message
    assert_match "must be defined before \"google/protobuf/unittest.proto\"", error.message
    assert pool
  end

  def test_redefining_a_name_from_another_descriptor_raises
    _, first = SchemaFixtures.load("google/protobuf/unittest_import_public.proto")
    _, second = SchemaFixtures.load("google/protobuf/unittest_import_public.proto")
    registry = Protostar::Types::Registry.new
    registry.define(first)
    assert_raises(Protostar::Error) { registry.define(second) }
  end

  def test_recursive_and_mutually_recursive_types_link
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    a = set["proto2_unittest.TestMutualRecursionA"]
    b = set["proto2_unittest.TestMutualRecursionB"]
    m = a.new(bb: {a: {bb: {optional_int32: 5}}})
    assert_instance_of b, m.bb
    assert_instance_of a, m.bb.a
    assert_equal m, a.decode(m.encode)
    r = set["proto2_unittest.TestRecursiveMessage"]
    deep = r.new(a: {a: {a: {i: 3}}})
    assert_equal 3, r.decode(deep.encode).a.a.a.i
  end

  def test_classes_are_anonymous_unless_named
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    assert_nil set["proto2_unittest.TestAllTypes"].name
    assert_match "proto2_unittest.TestAllTypes", set["proto2_unittest.TestAllTypes"].inspect
  end

  def test_name_assigns_constants_in_a_namespace
    pool, file = SchemaFixtures.load("google/protobuf/unittest_import.proto")
    namespace = Module.new
    registry = Protostar::Types::Registry.new
    pool.files.each { |f| registry.define(f, name: (f == file) ? namespace : nil) }
    assert_same registry.find("proto2_unittest_import.ImportMessage"), namespace::ImportMessage
    assert_same registry.find("proto2_unittest_import.ImportEnum"), namespace::ImportEnum
    assert_equal 7, namespace::ImportEnum::IMPORT_FOO
  end

  def test_nested_types_become_constants_of_their_parent
    pool, file = SchemaFixtures.load("google/protobuf/unittest_proto3.proto")
    namespace = Module.new
    registry = Protostar::Types::Registry.new
    pool.files.each { |f| registry.define(f, name: (f == file) ? namespace : Module.new) }
    all = namespace::TestAllTypes
    assert_same registry.find("proto3_unittest.TestAllTypes.NestedMessage"), all::NestedMessage
    assert_equal 2, all::NestedEnum::BAR
  end

  def test_global_registry
    pool, = SchemaFixtures.load("google/protobuf/unittest_empty.proto")
    types = Protostar::Types.define(pool.files.last)
    types.each { |full_name, type| assert_same type, Protostar::Types.find(full_name) }
    assert_same types, Protostar::Types.define(pool.files.last)
  end

  def test_enum_modules
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    enum = set["proto2_unittest.TestAllTypes.NestedEnum"]
    assert enum.frozen?
    assert_kind_of Protostar::Enum, enum
    assert_same set.pool.find_enum("proto2_unittest.TestAllTypes.NestedEnum"), enum.descriptor
    assert_equal 1, enum::FOO
    assert_equal(-1, enum::NEG)
    assert_equal :BAR, enum.lookup(2)
    assert_nil enum.lookup(99)
    assert_equal 3, enum.resolve(:BAZ)
    assert_equal 3, enum.resolve("BAZ")
    assert_nil enum.resolve(:NOPE)
    assert Ractor.shareable?(enum)
  end

  def test_enum_aliases
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    enum = set["proto2_unittest.TestEnumWithDupValue"]
    assert_equal 1, enum::FOO1
    assert_equal 1, enum::FOO2
    assert_equal :FOO1, enum.lookup(1), "the first name declared wins"
    assert_equal 1, enum.resolve(:FOO2)
  end

  def test_enum_constant_names_capitalise_the_first_letter
    assert_equal "Foo_bar", Protostar::Enum.constant_name("foo_bar")
    assert_equal "FOO", Protostar::Enum.constant_name("FOO")
    assert_nil Protostar::Enum.constant_name("_foo")
  end

  def test_classes_and_tables_are_shareable
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    klass = set["proto2_unittest.TestAllTypes"]
    assert Ractor.shareable?(klass)
    %i[__fields __by_number __by_name __encode_order __template __oneofs __required].each do |table|
      assert Ractor.shareable?(klass.public_send(table)), "#{table} is not shareable"
    end
  end

  def test_abstract_base_class
    assert_raises(NotImplementedError) { Protostar::Message.new }
  end
end
