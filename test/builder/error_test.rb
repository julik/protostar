# frozen_string_literal: true

require_relative "builder_support"

class BuilderErrorTest < Minitest::Test
  include BuilderSupport

  Error = Protostar::Builder::Error

  def error(&block)
    assert_raises(Error) { build(&block) }
  end

  def test_errors_carry_the_field_path
    e = error do |pb|
      pb.friends([1, 2]) do |i|
        pb.address { pb.street((i == 2) ? 5 : "ok") }
      end
    end
    assert_equal "friends[1].address.street", e.path
    assert_equal "friends[1].address.street: expects a String, got 5", e.message
    assert_kind_of Protostar::Error, e

    assert_equal "homes[1].city", error { |pb| pb.homes [{city: "a"}, {city: :b}] }.path
    assert_equal "places[7].city", error { |pb| pb.places(7 => {city: 1}) }.path
    assert_equal 'attrs["k"]', error { |pb| pb.attrs("k" => 1) }.path
    assert_equal "attrs[:k]", error { |pb| pb.attrs(k: "v") }.path
    assert_equal "", error { |pb| pb.set! :nope, 1 }.path
    assert_equal "address", error { |pb| pb.address { pb.set! :nope, 1 } }.path
  end

  def test_the_path_is_left_after_an_error_is_rescued
    pb = Protostar::Builder.new(Person)
    assert_raises(Error) { pb.friends([1]) { pb.address { pb.street 1 } } }
    assert_equal "id: expects an Integer in int32 range, got \"x\"", assert_raises(Error) { pb.id "x" }.message
  end

  def test_types_and_ranges
    {
      [:id, 2**31] => "id: expects an Integer in int32 range, got 2147483648",
      [:id, 1.0] => "id: expects an Integer in int32 range, got 1.0",
      [:crc, -1] => "crc: expects an Integer in fixed32 range, got -1",
      [:active, 1] => "active: expects true or false, got 1",
      [:weight, "1"] => "weight: expects a Numeric, got \"1\"",
      [:name, :sym] => "name: expects a String, got :sym",
      [:name, "\xFF"] => "name: expects valid UTF-8, got \"\\xFF\"",
      [:name, "\xFF".b] => "name: expects valid UTF-8, got \"\\xFF\"",
      [:kind, :NOPE] => "kind: expects a value of buildertest.Kind, got :NOPE",
      [:kind, 2**31] => "kind: expects a value of buildertest.Kind, got 2147483648",
      [:avatar, 1] => "avatar: expects a String, got 1",
      [:address, "x"] => "address: expects a buildertest.Address, a Hash or something with #to_h, got \"x\"",
      [:address, Person.new] => "address: expects a buildertest.Address, got a buildertest.Person",
      [:created_at, "2020"] => "created_at: expects a google.protobuf.Timestamp, a Hash or something with #to_h, got \"2020\"",
      [:ttl, Float::INFINITY] => "ttl: expects a finite duration, got Infinity",
      [:ttl, 10**12] => "ttl: is out of Duration's range: 1000000000000",
      [:attrs, ["a"]] => "attrs: is a map, it takes a Hash, got [\"a\"]",
      [:ids, [1, nil]] => "ids: expects an Integer in int32 range, got nil",
      [:homes, [1]] => "homes[0]: expects a buildertest.Address, a Hash or something with #to_h, got 1"
    }.each do |(field, value), message|
      assert_equal message, error { |pb| pb.set!(field, value) }.message
    end
    assert_equal "places[1]: a map value cannot be nil", error { |pb| pb.places(1 => nil) }.message
  end

  def test_unknown_fields
    assert_equal 'buildertest.Person has no field "nope"', error { |pb| pb.set! :nope, 1 }.message
    assert_equal 'buildertest.Person has no field "nope"', error { |pb| pb.merge!(nope: 1) }.message
    assert_equal 'buildertest.Person has no field "nope"', error { |pb| pb.extract!({nope: 1}, :nope) }.message
    e = error { |pb| pb.address { pb.name "x" } }
    assert_equal 'address: buildertest.Address has no field "name"', e.message
  end

  def test_misused_forms
    assert_equal "name: is not a message field, it cannot take a block", error { |pb| pb.name { 1 } }.message
    assert_equal "attrs: is not a message field, it cannot take a block", error { |pb| pb.attrs { 1 } }.message
    assert_equal "friends: needs a collection to go with the block", error { |pb| pb.friends { 1 } }.message
    assert_equal "friends: needs a collection (something with #each), got Integer", error { |pb| pb.friends(1) { 1 } }.message
    assert_equal "name: needs a value or a block", error { |pb| pb.name }.message
    assert_equal "merge! takes a Hash, got Array", error { |pb| pb.merge!([]) }.message
  end

  def test_writing_a_singular_field_twice
    assert_equal "name: is already set; pass overwrites: true to let the last value win",
      error { |pb| pb.name("a").name("b") }.message
    assert_equal "name: is already set; pass overwrites: true to let the last value win",
      error { |pb| pb.name("").name("b") }.message
    assert_equal "address: is already set; pass overwrites: true to let the last value win",
      error { |pb| pb.address { pb.street "a" }.address { pb.city "b" } }.message
    assert_equal "phone: oneof contact already has a value; pass overwrites: true to let the last one win",
      error { |pb| pb.email("a").phone("b") }.message
    assert_equal "postal: oneof contact already has a value; pass overwrites: true to let the last one win",
      error { |pb| pb.email("a").postal { pb.city "b" } }.message
  end

  def test_the_same_field_in_different_messages_is_not_twice
    bytes = build do |pb|
      pb.name "a"
      pb.friends([1, 2]) { |i| pb.name "f#{i}" }
    end
    assert_equal %w[f1 f2], decode(bytes).friends.map(&:name)
  end
end
