# frozen_string_literal: true

require "test_helper"
require "json"
require "objspace"

# Fields live in instance variables set in one order, so that every message
# of a class has the same object shape and YJIT reads them inline. A message
# whose ivars were set in other orders ends up with a "too complex" shape,
# a Hash of ivars, and loses that.
class MessageShapeTest < Minitest::Test
  def setup
    @set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = @set["proto2_unittest.TestAllTypes"]
  end

  def shape(object)
    dump = JSON.parse(ObjectSpace.dump(object))
    refute dump["too_complex_shape"], "#{object.class} has a too complex shape"
    skip "this Ruby does not dump shape ids" unless dump.key?("shape_id")
    dump["shape_id"]
  end

  def test_a_wide_message_has_one_shape_however_it_is_made
    assert_operator @all.__fields.size, :>=, 80
    source = RandomMessage.build(@all, random: Random.new(3), depth: 2, fill: 1.0)
    bytes = source.encode
    made = [
      @all.new,
      @all.new(optional_int32: 1, repeated_string: ["a"]),
      @all.decode(bytes),
      @all.decode(bytes).dup,
      @all.new.merge!(source),
      @all.new(optional_int32: 1).tap(&:clear!),
      @all.decode_json(source.to_json),
      @all.view(bytes).to_message
    ]
    # many classes and paths in one process, as an app has
    @set.types.each_value { |t| t.new.dup if t.is_a?(Class) }
    made.each { |m| assert_equal shape(made.first), shape(m) }
    frozen = [@all.decode(bytes, frozen: true), @all.new.freeze, source.clone(freeze: true)]
    frozen.each { |m| assert_equal shape(frozen.first), shape(m) }
  end

  def test_fields_are_slots_not_names
    m = @all.new(optional_int32: 7)
    assert_equal :@unknown, m.instance_variables.first
    assert_equal @all.__fields.size + 1, m.instance_variables.size
    assert_equal 7, m.instance_variable_get(@all.__by_name.fetch("optional_int32").ivar)
  end
end
