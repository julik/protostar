# frozen_string_literal: true

require "test_helper"

class WellKnownStructTest < Minitest::Test
  def setup
    set = CodecFixtures.load("google/protobuf/struct.proto")
    @struct = set["google.protobuf.Struct"]
    @value = set["google.protobuf.Value"]
    @list = set["google.protobuf.ListValue"]
  end

  def test_from_hash_and_to_h_with_nesting_and_nulls
    hash = {"a" => 1, "b" => [nil, "x", [true, {"c" => nil}]], "d" => {"e" => false}, "f" => nil}
    s = @struct.from_hash(hash)
    assert_equal({"a" => 1.0, "b" => [nil, "x", [true, {"c" => nil}]], "d" => {"e" => false}, "f" => nil}, s.to_h)
    assert_equal :null_value, s.fields["f"].which_kind
    assert_equal :list_value, s.fields["b"].which_kind
    assert_equal s, @struct.decode(s.encode)
    assert_equal '{"a":1,"b":[null,"x",[true,{"c":null}]],"d":{"e":false},"f":null}', s.to_json
  end

  def test_struct_accessors
    s = @struct.new
    s["n"] = 2
    s["l"] = [1, "two"]
    s["h"] = {"k" => "v"}
    assert_equal 2.0, s["n"]
    assert_instance_of @list, s["l"], "[] leaves nested lists as ListValue"
    assert_equal [1.0, "two"], s["l"].to_a
    assert_instance_of @struct, s["h"]
    assert_equal "v", s["h"]["k"]
    assert_nil s["missing"]
    assert s.has_key?("n")
    refute s.has_key?("missing")
    s["n"] = nil
    assert_nil s["n"]
    assert s.has_key?("n")
    e = assert_raises(Protostar::WellKnown::UnexpectedStructType) { s[:sym] = 1 }
    assert_equal "Struct keys must be strings.", e.message
    assert_raises(Protostar::WellKnown::UnexpectedStructType) { s["t"] = Object.new }
  end

  def test_value_to_ruby_and_from_ruby
    assert_nil @value.from_ruby(nil).to_ruby
    assert_equal 1.5, @value.from_ruby(1.5).to_ruby
    assert_equal 3.0, @value.from_ruby(3).to_ruby
    assert_equal 0.5, @value.from_ruby(Rational(1, 2)).to_ruby
    assert_equal "s", @value.from_ruby("s").to_ruby
    assert_equal false, @value.from_ruby(false).to_ruby
    nested = @value.from_ruby({"a" => [1]})
    assert_instance_of @struct, nested.to_ruby
    assert_equal({"a" => [1.0]}, nested.to_ruby(true))
    list = @value.from_ruby([1, [2]])
    assert_instance_of @list, list.to_ruby
    assert_equal [1.0, [2.0]], list.to_ruby(true)
    s = @struct.from_hash("x" => 1)
    assert_same s, @value.from_ruby(s).struct_value
    l = @list.from_a([1])
    assert_same l, @value.from_ruby(l).list_value
    assert_raises(Protostar::WellKnown::UnexpectedStructType) { @value.new.to_ruby }
    assert_raises(Protostar::WellKnown::UnexpectedStructType) { @value.from_ruby(:sym) }
    v = @value.new(string_value: "a")
    assert_same v, v.from_ruby(2)
    assert_equal :number_value, v.which_kind
  end

  def test_list_value
    l = @list.from_a([1, "a", nil, {"k" => true}])
    assert_equal 4, l.length
    assert_equal 1.0, l[0]
    assert_nil l[2]
    assert_instance_of @struct, l[3]
    assert_equal [1.0, "a", nil, {"k" => true}], l.to_a
    l << [2]
    assert_equal [2.0], l.to_a.last
    l[1] = "b"
    assert_equal "b", l[1]
    assert_equal [1.0, "b", nil], l.first(3)
    assert_equal [1.0, "b", nil, l[3], l[4]], l.each.to_a
    assert_equal 5, l.each.size
    assert_equal ["b"], l.select { |v| v.is_a?(String) }
    assert_equal '[1,"b",null,{"k":true},[2]]', l.to_json
  end

  def test_message_to_h_of_a_struct_field_stays_field_by_field
    holder = CodecFixtures.load("google/protobuf/test_messages_proto3.proto")
    all = holder["protobuf_test_messages.proto3.TestAllTypesProto3"]
    m = all.new(optional_struct: holder["google.protobuf.Struct"].from_hash("a" => 1))
    assert_equal({optional_struct: {fields: {"a" => {number_value: 1.0}}}}, m.to_h)
    assert_equal({"a" => 1.0}, m.optional_struct.to_h)
  end
end
