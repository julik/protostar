# frozen_string_literal: true

require "test/unit"
require "open3"
require "rbconfig"
require "google/protobuf"
require "google/protobuf/struct_pb"

# Struct, Value and ListValue behave as the gem's well_known_types.rb makes
# them, with or without that file required
class WellKnownTest < Test::Unit::TestCase
  Struct = Google::Protobuf::Struct
  Value = Google::Protobuf::Value
  ListValue = Google::Protobuf::ListValue

  def test_struct_from_hash_and_back
    hash = {"n" => 1, "s" => "x", "b" => true, "nil" => nil, "list" => [1, "a", [2]], "sub" => {"k" => false}}
    struct = Struct.from_hash(hash)
    assert_equal({"n" => 1.0, "s" => "x", "b" => true, "nil" => nil, "list" => [1.0, "a", [2.0]], "sub" => {"k" => false}},
      struct.to_h)
    assert_equal "x", struct["s"]
    assert_nil struct["missing"]
    assert_kind_of ListValue, struct["list"], "[] leaves nested lists as they are"
    assert_kind_of Struct, struct["sub"]
    assert struct.has_key?("n")
    assert !struct.has_key?("missing")
    assert_equal struct, Struct.decode(Struct.encode(struct))
  end

  def test_struct_assignment
    struct = Struct.new
    struct["a"] = 1
    struct["a"] = "replaced"
    struct["l"] = ListValue.from_a([1])
    assert_equal({"a" => "replaced", "l" => [1.0]}, struct.to_h)
    assert_raise(Google::Protobuf::UnexpectedStructType) { struct[:a] = 1 }
    assert_raise(Google::Protobuf::UnexpectedStructType) { struct["t"] = Time.now }
    assert_raise(Google::Protobuf::UnexpectedStructType) { Struct.from_hash("x" => Object.new) }
  end

  def test_value_from_ruby_and_to_ruby
    {nil => :null_value, 1.5 => :number_value, 2 => :number_value, "s" => :string_value, true => :bool_value,
     false => :bool_value, {"a" => 1} => :struct_value, [1] => :list_value}.each do |ruby, kind|
      value = Value.from_ruby(ruby)
      assert_equal kind, value.kind, ruby.inspect
    end
    assert_equal({"a" => [1.0]}, Value.from_ruby({"a" => [1]}).to_ruby(true))
    assert_kind_of Struct, Value.from_ruby({"a" => 1}).to_ruby
    assert_raise(Google::Protobuf::UnexpectedStructType) { Value.new.to_ruby }
    assert_raise(Google::Protobuf::UnexpectedStructType) { Value.from_ruby(:sym) }
  end

  def test_list_value
    list = ListValue.from_a([1, "a", {"k" => nil}])
    assert_equal 3, list.length
    assert_equal "a", list[1]
    list[1] = "b"
    list << false
    assert_equal [1.0, "b", {"k" => nil}, false], list.to_a
    assert_equal [1.0, "b"], list.first(2)
    assert_kind_of Struct, list[2]
  end

  def test_without_well_known_types_required
    script = <<~RUBY
      require "google/protobuf"
      require "google/protobuf/struct_pb"
      abort "well_known_types was loaded" if $LOADED_FEATURES.any? { |f| f.end_with?("google/protobuf/well_known_types.rb") }
      p Google::Protobuf::Struct.from_hash({"a" => "x", "b" => [1]}).to_h
    RUBY
    lib = File.expand_path("../../lib", __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
    assert status.success?, err
    assert_equal({"a" => "x", "b" => [1.0]}.inspect, out.chomp)
  end
end
