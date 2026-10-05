# frozen_string_literal: true

require "test_helper"

class AccessorsTest < Minitest::Test
  def setup
    @unittest = CodecFixtures.load("google/protobuf/unittest.proto")
    @proto3 = CodecFixtures.load("google/protobuf/unittest_proto3.proto")
    @all = @unittest["proto2_unittest.TestAllTypes"]
    @all3 = @proto3["proto3_unittest.TestAllTypes"]
  end

  def test_unset_fields_read_their_defaults
    m = @all.new
    assert_equal 0, m.optional_int32
    assert_equal 0.0, m.optional_float
    assert_equal false, m.optional_bool
    assert_equal "", m.optional_string
    assert_equal Encoding::UTF_8, m.optional_string.encoding
    assert_equal "".b, m.optional_bytes
    assert_equal Encoding::BINARY, m.optional_bytes.encoding
    assert_nil m.optional_nested_message
    assert_equal :FOO, m.optional_nested_enum, "an enum defaults to its first value"
    assert_equal [], m.repeated_int32
    assert_equal 41, m.default_int32
    assert_equal(-45, m.default_sint32)
    assert_equal 51.5, m.default_float
    assert_equal 52_000.0, m.default_double
    assert_equal true, m.default_bool
    assert_equal "hello", m.default_string
    assert_equal "world".b, m.default_bytes
    assert_equal :BAR, m.default_nested_enum
    assert_equal :FOREIGN_BAR, m.default_foreign_enum
    assert_equal :IMPORT_BAR, m.default_import_enum
    assert_equal "abc", m.default_string_piece
  end

  def test_has_and_clear_exist_only_with_presence
    m = @all.new
    refute m.has_optional_int32?
    m.optional_int32 = 0
    assert m.has_optional_int32?, "explicit presence: set to the default is still set"
    m.clear_optional_int32
    refute m.has_optional_int32?
    refute_respond_to m, :has_repeated_int32?
    refute_respond_to m, :clear_repeated_int32

    p3 = @all3.new
    refute_respond_to p3, :has_optional_int32?
    refute_respond_to p3, :clear_optional_int32
    assert_respond_to p3, :has_optional_nested_message?, "message fields always have presence"
    assert_respond_to p3, :has_oneof_uint32?, "oneof members always have presence"
  end

  def test_proto3_implicit_presence
    m = @all3.new(optional_int32: 5)
    assert_equal 5, m.optional_int32
    m.optional_int32 = nil
    assert_equal 0, m.optional_int32
    m.optional_int32 = 0
    assert_equal "".b, m.encode, "zero values are not written without presence"
    assert_equal({}, m.to_h)
  end

  def test_oneof
    m = @all.new
    assert_nil m.which_oneof_field
    m.oneof_uint32 = 7
    assert_equal :oneof_uint32, m.which_oneof_field
    m.oneof_string = "x"
    assert_equal :oneof_string, m.which_oneof_field
    refute m.has_oneof_uint32?
    assert_equal 0, m.oneof_uint32
    m.oneof_nested_message = {bb: 2}
    assert_equal :oneof_nested_message, m.which_oneof_field
    assert_equal "", m.oneof_string
    m.oneof_nested_message = nil
    assert_nil m.which_oneof_field
  end

  def test_proto3_optional_has_no_which
    set = CodecFixtures.load("google/protobuf/unittest_proto3_optional.proto")
    klass = set["proto2_unittest.TestProto3Optional"]
    m = klass.new
    refute_respond_to m, :which__optional_int32
    refute m.has_optional_int32?
    m.optional_int32 = 0
    assert m.has_optional_int32?
    assert_equal "\x08\x00".b, m.encode, "proto3 optional writes an explicit zero"
    assert_equal({optional_int32: 0}, m.to_h)
    refute_respond_to m, :has_singular_int32?
    m.optional_nested_enum = :UNSPECIFIED
    assert m.has_optional_nested_enum?
    decoded = klass.decode(m.encode)
    assert decoded.has_optional_int32?
    assert decoded.has_optional_nested_enum?
    refute decoded.has_optional_string?
  end

  def test_enum_reader_and_writer
    m = @all3.new
    assert_equal :ZERO, m.optional_nested_enum
    m.optional_nested_enum = :BAR
    assert_equal :BAR, m.optional_nested_enum
    m.optional_nested_enum = 3
    assert_equal :BAZ, m.optional_nested_enum, "known numbers read as their name"
    m.optional_nested_enum = 99
    assert_equal 99, m.optional_nested_enum, "open enums keep numbers without a name"
    assert_raises(Protostar::TypeError) { m.optional_nested_enum = :NOPE }
    assert_raises(Protostar::TypeError) { m.optional_nested_enum = 2**31 }
    assert_raises(Protostar::TypeError) { m.optional_nested_enum = "BAR" }

    closed = @all.new
    closed.optional_nested_enum = -1
    assert_equal :NEG, closed.optional_nested_enum
    assert_raises(Protostar::TypeError) { closed.optional_nested_enum = 99 }
  end

  def test_enum_alias_is_stored_by_its_first_name
    set = CodecFixtures.load("google/protobuf/test_messages_proto3.proto")
    klass = set["protobuf_test_messages.proto3.TestAllTypesProto3"]
    enum = set["protobuf_test_messages.proto3.TestAllTypesProto3.AliasedEnum"]
    m = klass.new(optional_aliased_enum: :moo)
    assert_equal :ALIAS_BAZ, m.optional_aliased_enum
    assert_equal klass.new(optional_aliased_enum: :bAz), m
    assert_equal 2, enum::Moo, "a lower-case value name gets a capitalised constant"
    assert_equal 2, enum::BAz
    assert_equal 2, enum::MOO
    assert_equal 2, enum.resolve(:moo)
  end

  def test_repeated_fields_are_plain_arrays
    m = @all.new
    list = m.repeated_int32
    assert_instance_of Array, list
    list << 1 << 2
    assert_equal [1, 2], m.repeated_int32
    assert_same list, m.repeated_int32
    source = [3, 4]
    m.repeated_int32 = source
    refute_same source, m.repeated_int32, "the writer copies"
    source << 5
    assert_equal [3, 4], m.repeated_int32
    assert_raises(Protostar::TypeError) { m.repeated_int32 = [1, "2"] }
    assert_raises(Protostar::TypeError) { m.repeated_int32 = 1 }
    m.repeated_nested_message = [{bb: 1}, {bb: 2}]
    assert_equal [1, 2], m.repeated_nested_message.map(&:bb)
    m.repeated_int32 = nil
    assert_equal [], m.repeated_int32
  end

  def test_maps_are_plain_hashes
    set = CodecFixtures.load("google/protobuf/map_unittest.proto")
    klass = set["proto2_unittest.TestMap"]
    m = klass.new(map_int32_int32: {1 => 2}, map_string_foreign_message: {"a" => {c: 1}})
    assert_instance_of Hash, m.map_int32_int32
    assert_equal({1 => 2}, m.map_int32_int32)
    assert_equal 1, m.map_string_foreign_message["a"].c
    m.map_int32_int32[3] = 4
    assert_equal({1 => 2, 3 => 4}, m.map_int32_int32)
    assert_raises(Protostar::TypeError) { m.map_int32_int32 = {"a" => 1} }
    assert_raises(Protostar::TypeError) { m.map_int32_int32 = {1 => "a"} }
    assert_raises(Protostar::TypeError) { m.map_int32_int32 = [[1, 2]] }
    m.map_int32_enum = {1 => :MAP_ENUM_BAR, 2 => 77}
    assert_equal({1 => :MAP_ENUM_BAR, 2 => 77}, m.map_int32_enum)
  end

  def test_message_fields_take_the_class_or_a_hash
    m = @all.new
    nested = m.class.__by_name[:optional_nested_message].message_class
    m.optional_nested_message = nested.new(bb: 1)
    assert_equal 1, m.optional_nested_message.bb
    m.optional_nested_message = {bb: 2}
    assert_equal 2, m.optional_nested_message.bb
    assert_raises(Protostar::TypeError) { m.optional_nested_message = @all.new }
    assert_raises(Protostar::TypeError) { m.optional_nested_message = 1 }
    m.optional_nested_message = nil
    refute m.has_optional_nested_message?
  end

  def test_square_brackets
    m = @all.new
    m[:optional_int32] = 4
    m["optional_string"] = "s"
    assert_equal 4, m["optional_int32"]
    assert_equal "s", m[:optional_string]
    assert_equal [], m[:repeated_int32]
    assert_equal 41, m[:default_int32]
    assert_raises(ArgumentError) { m[:nope] }
    assert_raises(ArgumentError) { m[:nope] = 1 }
  end

  def test_new_with_hash_and_keywords
    a = @all.new(optional_int32: 1, optional_string: "x")
    b = @all.new({"optional_int32" => 1, :optional_string => "x"})
    c = @all.new("optional_int32" => 1, "optional_string" => "x")
    assert_equal a, b
    assert_equal a, c
    error = assert_raises(ArgumentError) { @all.new(nope: 1) }
    assert_match "nope", error.message
    nested = @all.new(optional_nested_message: {bb: 3}, repeatedgroup: [{a: 1}], optionalgroup: {a: 2})
    assert_equal 3, nested.optional_nested_message.bb
    assert_equal 1, nested.repeatedgroup.first.a
    assert_equal 2, nested.optionalgroup.a
  end

  def test_fields_named_like_ruby_methods_go_through_brackets
    pool = Protostar::Schema::Pool.new
    file = SchemaFixtures.add(pool, {
      name: "clash.proto", package: "clash", syntax: "proto3",
      message_type: [{name: "M", field: [
        {name: "hash", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32},
        {name: "class", number: 2, label: :LABEL_OPTIONAL, type: :TYPE_STRING},
        {name: "encode", number: 3, label: :LABEL_OPTIONAL, type: :TYPE_BOOL},
        {name: "plain", number: 4, label: :LABEL_OPTIONAL, type: :TYPE_INT32}
      ]}]
    })
    klass = Protostar::Types::Registry.new.define(file).fetch("clash.M")
    m = klass.new(hash: 5, class: "c", encode: true, plain: 1)
    assert_equal klass, m.class
    assert_kind_of Integer, m.hash
    assert_equal 5, m[:hash]
    assert_equal "c", m[:class]
    assert_equal true, m[:encode]
    assert_equal 1, m.plain
    m.hash = 6
    assert_equal 6, m[:hash]
    assert_equal m, klass.decode(m.encode)
  end
end
