# frozen_string_literal: true

require_relative "builder_support"

# overwrites: true and repeated: :replace, the options that rely on readers
# applying protobuf's merge rules
class BuilderOverwritesTest < Minitest::Test
  include BuilderSupport

  def test_a_later_scalar_wins_even_when_it_is_zero
    bytes = build(overwrites: true) do |pb|
      pb.name "PENDING"
      pb.id 5
      pb.name "DONE"
      pb.id 0
    end
    person = decode(bytes)
    assert_equal "DONE", person.name
    assert_equal 0, person.id
    assert_equal Person.new(name: "PENDING", id: 5).encode + Person.new(name: "DONE").encode + "\x10\x00".b, bytes
  end

  def test_a_zero_first_write_still_writes_nothing
    assert_equal Person.new(name: "x").encode, build(overwrites: true) { |pb| pb.name("").name("x") }
  end

  def test_a_nested_message_written_again_is_merged
    bytes = build(overwrites: true) do |pb|
      pb.address { pb.street "a" }
      pb.name "between"
      pb.address { pb.city "b" }
      pb.address { pb.street "c" }
    end
    assert_equal Address.new(street: "c", city: "b"), decode(bytes).address
  end

  def test_oneof_last_wins
    bytes = build(overwrites: true) do |pb|
      pb.email "a@b"
      pb.postal { pb.city "x" }
      pb.phone "123"
    end
    person = decode(bytes)
    assert_equal :phone, person.which_contact
    assert_equal "123", person.phone
    assert_nil person.postal

    person = decode(build(overwrites: true) { |pb| pb.phone("1").email("") })
    assert_equal :email, person.which_contact
    assert_equal "", person.email
  end

  def test_repeated_fields_append_by_default
    bytes = build do |pb|
      pb.nicknames %w[a b]
      pb.nicknames ["c"]
      pb.ids [1]
      pb.ids [2]
      pb.homes [{city: "x"}]
      pb.homes [{city: "y"}]
    end
    person = decode(bytes)
    assert_equal %w[a b c], person.nicknames
    assert_equal [1, 2], person.ids
    assert_equal %w[x y], person.homes.map(&:city)
  end

  def test_repeated_replace_keeps_the_last_assignment
    bytes = build(repeated: :replace) do |pb|
      pb.nicknames %w[a b]
      pb.nicknames "c"
      pb.ids [1, 2]
      pb.ids [3]
      pb.homes [{city: "x"}]
      pb.homes [{city: "y"}, {city: "z"}]
      pb.name "x"
    end
    person = decode(bytes)
    assert_equal %w[c], person.nicknames
    assert_equal [3], person.ids
    assert_equal %w[y z], person.homes.map(&:city)
    assert_equal Person.new(name: "x", nicknames: %w[c], homes: [{city: "y"}, {city: "z"}], ids: [3]).encode, bytes
  end

  def test_repeated_replace_holds_lists_per_message
    bytes = build(repeated: :replace) do |pb|
      pb.nicknames ["outer"]
      pb.friends([1, 2]) { |i| pb.nicknames ["inner#{i}"] }
    end
    person = decode(bytes)
    assert_equal ["outer"], person.nicknames
    assert_equal [["inner1"], ["inner2"]], person.friends.map(&:nicknames)
  end

  def test_repeated_replace_rejects_an_unknown_mode
    assert_raises(ArgumentError) { Protostar::Builder.new(Person, repeated: :merge) }
  end
end
