# frozen_string_literal: true

require_relative "builder_support"
require "date"

class BuilderCoercionTest < Minitest::Test
  include BuilderSupport

  def test_time_and_datetime_become_timestamps
    time = Time.at(1_700_000_000, 123_456_789, :nanosecond)
    assert_equal Person.new(created_at: {seconds: 1_700_000_000, nanos: 123_456_789}).encode,
      build { |pb| pb.created_at time }
    datetime = DateTime.new(2001, 2, 3, 4, 5, 6.5r)
    assert_equal Time.utc(2001, 2, 3, 4, 5, 6.5r), decode(build { |pb| pb.created_at datetime }).created_at.to_time.utc
    assert_equal Person.new(created_at: {seconds: -1, nanos: 500_000_000}).encode,
      build { |pb| pb.created_at Time.at(-0.5r) }
    assert_equal Person.new(created_at: {}).encode, build { |pb| pb.created_at Time.at(0) }
  end

  def test_numerics_become_durations
    {
      90 => [90, 0], 1.5 => [1, 500_000_000], -1.5 => [-1, -500_000_000], 1.1 => [1, 100_000_000],
      Rational(1, 3) => [0, 333_333_333], -0.25 => [0, -250_000_000], 0.9999999999 => [1, 0]
    }.each do |value, (seconds, nanos)|
      assert_equal Person.new(ttl: {seconds: seconds, nanos: nanos}).encode, build { |pb| pb.ttl value }, value.inspect
    end
  end

  def test_scalars_become_wrappers
    assert_equal Person.new(maybe_name: {value: "x"}).encode, build { |pb| pb.maybe_name "x" }
    assert_equal Person.new(maybe_name: {}).encode, build { |pb| pb.maybe_name "" }
    assert_equal Person.new(big: {value: 2**40}).encode, build { |pb| pb.big 2**40 }
    assert_equal Person.new(maybe_name: {value: "h"}).encode, build { |pb| pb.maybe_name({value: "h"}) }
  end

  def test_well_known_types_still_take_their_fields
    assert_equal Person.new(created_at: {seconds: 5}).encode, build { |pb| pb.created_at { pb.seconds 5 } }
    assert_equal Person.new(ttl: {seconds: 5}).encode, build { |pb| pb.ttl(seconds: 5) }
    assert_equal Person.new(created_at: {seconds: 5}).encode, build { |pb| pb.created_at Timestamp.new(seconds: 5) }
  end

  def test_hashes_and_to_h_become_messages
    point = Struct.new(:street, :city).new("Main", "Paris")
    assert_equal Person.new(address: {street: "Main", city: "Paris"}).encode, build { |pb| pb.address point }
    assert_equal Person.new(address: {street: "Main"}).encode, build { |pb| pb.address({"street" => "Main"}) }
    assert_equal Person.new(homes: [{city: "Paris"}]).encode, build { |pb| pb.homes [point.to_h.slice(:city)] }
  end

  def test_enums_by_symbol_string_or_number
    expected = Person.new(kind: :KIND_B).encode
    assert_equal [expected] * 3, [build { |pb| pb.kind :KIND_B }, build { |pb| pb.kind "KIND_B" }, build { |pb| pb.kind 2 }]
    assert_equal Person.new(kind: 99).encode, build { |pb| pb.kind 99 }
  end

  def test_numbers
    assert_equal Person.new(weight: 3.0).encode, build { |pb| pb.weight 3 }
    assert_equal Person.new(weight: 0.5).encode, build { |pb| pb.weight Rational(1, 2) }
    assert_equal Person.new(ratio: 3.4028235e38).encode, build { |pb| pb.ratio 3.40282347e+38 }
    assert_equal Person.new(ratio: Float::INFINITY).encode, build { |pb| pb.ratio 1e40 }
    assert_equal Person.new(id: -1).encode, build { |pb| pb.id(-1) }
    assert_equal 11, build { |pb| pb.id(-1) }.bytesize
  end

  def test_strings_are_checked_and_converted_to_utf8
    assert_equal Person.new(name: "é").encode, build { |pb| pb.name "é".encode("ISO-8859-1") }
    assert_equal Person.new(name: "é").encode, build { |pb| pb.name "é".b }
    assert_equal Person.new(name: "abc").encode, build { |pb| pb.name "abc".encode("US-ASCII") }
    assert_equal Person.new(avatar: "é".b).encode, build { |pb| pb.avatar "é" }
  end

  def test_message_values_inside_maps
    point = Struct.new(:street, :city).new("Main", nil)
    assert_equal Person.new(places: {1 => {street: "Main"}}).encode, build { |pb| pb.places(1 => point) }
  end
end
