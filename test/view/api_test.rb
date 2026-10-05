# frozen_string_literal: true

require "test_helper"

class ViewApiTest < Minitest::Test
  def setup
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = set["proto2_unittest.TestAllTypes"]
    @message = @all.new(
      optional_int32: 5, optional_string: "hello", optional_bytes: "\x00\xff".b, optional_double: 2.5,
      optional_nested_message: {bb: 7}, optional_nested_enum: :BAZ,
      repeated_int32: [1, 2, 3], repeated_string: %w[a b], repeated_nested_message: [{bb: 1}, {bb: 2}, {bb: 3}],
      oneof_string: "one"
    )
    @bytes = @message.encode
    @view = @all.view(@bytes)
  end

  def test_view_class
    assert_same @all::View, @all.view_class
    assert_instance_of @all::View, @view
    assert_operator @all::View, :<, Protostar::View
    assert_same @all, @all::View.message_class
    assert_same @all.descriptor, @view.descriptor
    assert_equal "proto2_unittest.TestAllTypes", @view.descriptor.full_name
  end

  def test_readers
    assert_equal 5, @view.optional_int32
    assert_equal "hello", @view.optional_string
    assert_equal Encoding::UTF_8, @view.optional_string.encoding
    assert_equal Encoding::BINARY, @view.optional_bytes.encoding
    assert_predicate @view.optional_string, :frozen?
    assert_equal 2.5, @view.optional_double
    assert_equal 7, @view.optional_nested_message.bb
    assert_equal :BAZ, @view.optional_nested_enum
    assert @view.has_optional_int32?
    refute @view.has_optional_int64?
    assert_equal 0, @view.optional_int64
    assert_equal :FOO, @all.view("").optional_nested_enum
    assert_nil @view.optional_foreign_message
    assert_equal :oneof_string, @view.which_oneof_field
    assert_equal 5, @view[:optional_int32]
    assert_equal 5, @view["optional_int32"]
    assert_raises(ArgumentError) { @view[:nope] }
  end

  def test_reads_are_kept
    assert_same @view.optional_string, @view.optional_string
    assert_same @view.optional_nested_message, @view.optional_nested_message
    assert_same @view.repeated_nested_message, @view.repeated_nested_message
    assert_same @view.repeated_nested_message[1], @view.repeated_nested_message[1]
    assert_same @view.repeated_int32.to_a, @view.repeated_int32.to_a
  end

  def test_views_are_read_only
    assert_predicate @view, :frozen?
    assert_raises(FrozenError) { @view.optional_int32 = 1 }
    assert_raises(FrozenError) { @view[:optional_int32] = 1 }
    assert_raises(FrozenError) { @view.clear_optional_int32 }
    assert_raises(FrozenError) { @view.merge!(@view) }
    assert_raises(FrozenError) { @view.clear! }
    refute_respond_to @view.repeated_int32, :<<
  end

  def test_repeated
    list = @view.repeated_nested_message
    assert_kind_of Protostar::View::Repeated, list
    assert_kind_of Enumerable, list
    assert_equal 3, list.size
    assert_equal 3, list.length
    refute_empty list
    assert_equal 3, list[-1].bb
    assert_nil list[3]
    assert_nil list[-4]
    assert_equal [2, 3], list[1, 2].map(&:bb)
    assert_equal [1, 2], list[0..1].map(&:bb)
    assert_equal [1, 2, 3], list.map(&:bb)
    assert_equal [1, 2, 3], list.each.map(&:bb)
    assert_equal 1, list.first.bb
    assert_equal [1, 2, 3], @view.repeated_int32.to_a
    assert_predicate @view.repeated_int32.to_a, :frozen?
    assert_equal [1, 2, 3], @view.repeated_int32
    assert_equal @view.repeated_int32, [1, 2, 3]
    assert_equal %w[a b], @view.repeated_string
    assert_equal "[1, 2, 3]", @view.repeated_int32.inspect
    assert_empty @view.repeated_double
  end

  def test_map
    maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
    view = maps.view(maps.new(map_string_string: {"a" => "1", "b" => "2"}, map_int32_foreign_message: {3 => {c: 4}}).encode)
    map = view.map_string_string
    assert_kind_of Protostar::View::Map, map
    assert_equal "1", map["a"]
    assert_nil map["z"]
    assert map.key?("b")
    assert map.include?("b")
    refute map.key?("z")
    assert_equal %w[a b], map.keys
    assert_equal %w[1 2], map.values
    assert_equal 2, map.size
    assert_equal({"a" => "1", "b" => "2"}, map.to_h)
    assert_equal [["a", "1"], ["b", "2"]], map.each.to_a
    assert_equal map, {"a" => "1", "b" => "2"}
    assert_equal "1", map.fetch("a")
    assert_raises(KeyError) { map.fetch("z") }
    assert_equal 4, view.map_int32_foreign_message[3].c
    assert_same view.map_int32_foreign_message[3], view.map_int32_foreign_message[3]
    assert_empty view.map_int32_int32
    assert_equal({}, view.map_int32_int32.to_h)
  end

  def test_to_message_and_equality
    assert_equal @message, @view.to_message
    refute_predicate @view.to_message, :frozen?
    frozen = @view.to_message(frozen: true)
    assert Ractor.shareable?(frozen)
    assert_equal @view, @message
    assert_equal @view, @all.view(@bytes)
    refute_equal @view, @all.view(@all.new(optional_int32: 6).encode)
    refute_equal @view, @message.optional_nested_message
    assert_equal @view.hash, @all.view(@bytes).hash
  end

  def test_encode_returns_the_bytes
    assert_same @bytes, @view.encode
    assert_same @bytes, @view.to_proto
    nested = @view.optional_nested_message
    assert_equal @message.optional_nested_message.encode, nested.encode
    assert_equal Encoding::BINARY, nested.encode.encoding
  end

  def test_offset_and_length
    framed = "junk".b + @bytes + "more junk".b
    view = @all.view(framed, offset: 4, length: @bytes.bytesize)
    assert_equal @message, view.to_message
    assert_equal @bytes, view.encode
    assert_equal "hello", view.optional_string
    tail = @all.view("xx".b + @bytes, offset: 2)
    assert_equal 5, tail.optional_int32
  end

  def test_inspect_and_to_h
    assert_equal @message.to_h, @view.to_h
    assert_match(/\A#<view proto2_unittest.TestAllTypes optional_int32: 5, /, @view.inspect)
    assert_includes @view.inspect, "optional_nested_message: #<view proto2_unittest.TestAllTypes.NestedMessage bb: 7>"
    assert_equal "#<view proto2_unittest.TestAllTypes>", @all.view("").inspect
  end

  def test_freeze_index_keeps_working
    view = @all.view(@bytes.dup.freeze).freeze_index
    assert_same view, view.freeze_index
    assert Ractor.shareable?(view)
    assert_equal @message.to_h, view.to_h
    assert_equal 2, view.repeated_nested_message[1].bb
    refute Ractor.shareable?(@all.view(@bytes.dup).freeze_index), "the buffer is not frozen"
  end

  def test_a_nested_type_called_view_keeps_the_constant
    file = Protostar::Compiler.new.compile(["v.proto"], sources: {"v.proto" => <<~PROTO}).last
      syntax = "proto3";
      package v;
      message Outer { message View { int32 x = 1; } View inner = 1; string name = 2; }
      message Plain { int32 y = 1; }
    PROTO
    namespace = Module.new
    Protostar::Types.define(file, name: namespace, registry: Protostar::Types::Registry.new)
    outer = namespace::Outer
    refute_operator outer::View, :<, Protostar::View
    assert_equal "v.Outer.View", outer::View.descriptor.full_name
    assert_operator outer.view_class, :<, Protostar::View
    view = outer.view(outer.new(inner: {x: 4}, name: "n").encode)
    assert_equal 4, view.inner.x
    assert_operator namespace::Plain::View, :<, Protostar::View
  end

  def test_fields_named_like_view_methods
    file = Protostar::Compiler.new.compile(["w.proto"], sources: {"w.proto" => <<~PROTO}).last
      syntax = "proto3";
      package w;
      message Odd { int32 encode = 1; int32 to_message = 2; int32 hash = 3; int32 __f0 = 4; int32 class = 5; }
    PROTO
    odd = Protostar::Types.define(file, registry: Protostar::Types::Registry.new).fetch("w.Odd")
    view = odd.view(odd.new(encode: 1, to_message: 2, hash: 3, __f0: 4, class: 5).encode)
    assert_equal [1, 2, 3, 4, 5], %i[encode to_message hash __f0 class].map { |name| view[name] }
    assert_kind_of String, view.encode
    assert_kind_of Protostar::Message, view.to_message
    assert_equal odd::View, view.class
  end
end
