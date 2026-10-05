# frozen_string_literal: true

require_relative "builder_support"

# Every form of the DSL, compared byte for byte with encoding the
# equivalent message. Packed fields have the highest numbers in the test
# schema: the builder writes their runs when the message ends, and the
# encoder writes fields in number order, so the two agree.
class BuilderDslTest < Minitest::Test
  include BuilderSupport

  Friend = Struct.new(:name, :id)
  Place = Struct.new(:street, :city)

  def test_scalars_in_number_order_match_encode
    bytes = build do |pb|
      pb.name "Jane"
      pb.id 42
      pb.kind :KIND_B
      pb.avatar "\x00\xFF".b
      pb.weight 72.5
      pb.ratio 0.25
      pb.delta(-3)
      pb.crc 7
      pb.active true
    end
    expected = Person.new(name: "Jane", id: 42, kind: :KIND_B, avatar: "\x00\xFF".b, weight: 72.5, ratio: 0.25,
      delta: -3, crc: 7, active: true)
    assert_equal expected.encode, bytes
  end

  def test_zero_values_of_implicit_fields_are_left_out_and_presence_fields_kept
    bytes = build do |pb|
      pb.name ""
      pb.id 0
      pb.active false
      pb.weight 0.0
      pb.score 0
    end
    assert_equal Person.new(score: 0).encode, bytes
    assert_equal "\x78\x00".b, bytes
    assert_equal "\x89\x01".b + [-0.0].pack("E"), build { |pb| pb.weight(-0.0) }
  end

  def test_nested_block
    bytes = build do |pb|
      pb.name "Jane"
      pb.address do
        pb.street "Main"
        pb.city "Springfield"
      end
    end
    assert_equal Person.new(name: "Jane", address: {street: "Main", city: "Springfield"}).encode, bytes
  end

  def test_nested_block_given_a_value_yields_it
    bytes = build { |pb| pb.address(Friend.new("Elm", 1)) { |a| pb.street a.name } }
    assert_equal Person.new(address: {street: "Elm"}).encode, bytes
  end

  def test_collection_block_writes_one_element_per_item
    friends = [Friend.new("Ann", 1), Friend.new("Bob", 2)]
    bytes = build do |pb|
      pb.friends(friends) do |f|
        pb.name f.name
        pb.id f.id
        pb.friends([f]) { |ff| pb.name "#{ff.name}'s friend" }
      end
    end
    expected = Person.new(friends: [
      {name: "Ann", id: 1, friends: [{name: "Ann's friend"}]},
      {name: "Bob", id: 2, friends: [{name: "Bob's friend"}]}
    ])
    assert_equal expected.encode, bytes
  end

  def test_collection_block_takes_any_enumerable
    bytes = build { |pb| pb.friends(1..3) { |i| pb.id i } }
    assert_equal Person.new(friends: [{id: 1}, {id: 2}, {id: 3}]).encode, bytes
  end

  def test_repeated_scalars_and_messages_from_arrays
    jane = Person.new(name: "Jane")
    bytes = build do |pb|
      pb.friends [jane, {name: "Hash"}, Friend.new("Struct", 3)]
      pb.nicknames %w[a b]
      pb.nicknames "c"
    end
    expected = Person.new(friends: [{name: "Jane"}, {name: "Hash"}, {name: "Struct", id: 3}], nicknames: %w[a b c])
    assert_equal expected.encode, bytes
  end

  def test_packed_runs_are_collected_per_field_and_written_when_the_message_ends
    bytes = build do |pb|
      pb.ids [1, 2]
      pb.name "x"
      pb.ids 300
      pb.kinds [:KIND_A, 2, "KIND_A"]
      pb.scores [1.5, 2]
      pb.deltas [-1, 1]
      pb.flags [true, false]
      pb.ids []
    end
    expected = Person.new(name: "x", ids: [1, 2, 300], kinds: [:KIND_A, :KIND_B, :KIND_A], scores: [1.5, 2.0],
      deltas: [-1, 1], flags: [true, false])
    assert_equal expected.encode, bytes
  end

  def test_packed_runs_inside_nested_messages_end_with_them
    bytes = build do |pb|
      pb.friends([1]) { |i| pb.ids [i, i + 1] }
      pb.name "after"
    end
    assert_equal Person.new(friends: [{ids: [1, 2]}], name: "after"), decode(bytes)
    assert_equal Person.new(friends: [{ids: [1, 2]}]).encode, bytes[0...-7]
  end

  def test_maps
    bytes = build do |pb|
      pb.attrs("a" => "b", "c" => "")
      pb.places(1 => {street: "x"}, 2 => Address.new(city: "y"), 3 => {})
    end
    expected = Person.new(attrs: {"a" => "b", "c" => ""}, places: {1 => {street: "x"}, 2 => {city: "y"}, 3 => {}})
    assert_equal expected.encode, bytes
  end

  def test_map_from_anything_with_to_hash
    hashlike = Object.new
    def hashlike.to_hash = {"k" => "v"}
    assert_equal Person.new(attrs: {"k" => "v"}).encode, build { |pb| pb.attrs hashlike }
  end

  def test_message_instance_is_written_as_its_encoding
    address = Address.new(street: "x")
    assert_equal Person.new(address: address).encode, build { |pb| pb.address address }
  end

  def test_extract_from_objects_and_hashes
    user = Friend.new("Jane", 7)
    from_object = build { |pb| pb.extract!(user, :name, :id) }
    from_symbols = build { |pb| pb.extract!({name: "Jane", id: 7}, :name, :id) }
    from_strings = build { |pb| pb.extract!({"name" => "Jane", "id" => 7}, :name, "id") }
    expected = Person.new(name: "Jane", id: 7).encode
    assert_equal [expected] * 3, [from_object, from_symbols, from_strings]
  end

  def test_set_with_attribute_names_extracts_into_nested_messages
    friends = [Friend.new("Ann", 1), Friend.new("Bob", 2)]
    bytes = build do |pb|
      pb.set! :friends, friends, :name, :id
      pb.set! :address, Place.new("Elm", "Paris"), :street
    end
    assert_equal Person.new(friends: [{name: "Ann", id: 1}, {name: "Bob", id: 2}]).encode +
      Person.new(address: {street: "Elm"}).encode, bytes
    assert_raises(Protostar::Builder::Error) { build { |pb| pb.set! :name, friends.first, :name } }
    error = assert_raises(Protostar::Builder::Error) { build { |pb| pb.set! :address, friends.first, :name } }
    assert_equal 'address: buildertest.Address has no field "name"', error.message
  end

  def test_set_and_merge
    bytes = build do |pb|
      pb.set! "name", "Jane"
      pb.set!(:address) { pb.set! :street, "x" }
      pb.merge!(id: 3, "nicknames" => ["n"], friends: [{name: "f"}], email: nil)
    end
    assert_equal Person.new(name: "Jane", id: 3, address: {street: "x"}, nicknames: ["n"], friends: [{name: "f"}]),
      decode(bytes)
  end

  def test_nil_writes_nothing
    assert_equal "", build { |pb|
      pb.name nil
      pb.address nil
      pb.friends nil
      pb.attrs nil
      pb.ids nil
    }
  end

  def test_names_taken_by_object_methods_go_through_set
    refute_includes Protostar::Builder.for(Person).public_instance_methods(false), :format
    assert_equal Person.new(format: "pb").encode, build { |pb| pb.set! :format, "pb" }
  end

  def test_field_methods_are_methods
    klass = Protostar::Builder.for(Person)
    assert_operator klass, :<, Protostar::Builder
    assert_same klass, Protostar::Builder.for(Person)
    assert_raises(ArgumentError) { Protostar::Builder.for(Person.descriptor) }
    assert_raises(ArgumentError) { Protostar::Builder.for(String) }
    %i[name friends street city seconds nanos value].each { |m| assert_includes klass.public_instance_methods, m }
    refute_operator klass.instance_method(:method_missing).owner, :<=, Protostar::Builder
    assert_raises(NoMethodError) { build { |pb| pb.nope 1 } }
    assert_equal "#<Class Protostar::Builder(buildertest.Person)>", klass.inspect
    assert_predicate klass, :frozen?
  end

  def test_binds_to_a_descriptor_through_the_global_registry
    require "protostar/google/protobuf/duration_pb"
    duration = Protostar::Google::Protobuf::Duration
    assert_same Protostar::Builder.for(duration), Protostar::Builder.for(duration.descriptor)
    assert_equal duration.new(seconds: 5), Protostar::Builder.message(duration.descriptor) { |pb| pb.seconds 5 }
  end

  def test_message_and_write_and_new
    msg = Protostar::Builder.message(Person) { |pb| pb.name "Jane" }
    assert_equal Person.new(name: "Jane"), msg

    io = StringIO.new(+"".b)
    assert_same io, Protostar::Builder.write(io, Person) { |pb| pb.ids [1] }
    assert_equal Person.new(ids: [1]).encode, io.string

    pb = Protostar::Builder.new(Person)
    pb.name "x"
    pb.ids [1]
    assert_equal Person.new(name: "x", ids: [1]).encode, pb.target!
    assert_match(/#<Protostar::Builder buildertest.Person>/, pb.inspect)

    target = +"prefix"
    Protostar::Builder.new(Person, target).name("x").target!
    assert_equal "prefix".b + Person.new(name: "x").encode, target
  end

  def test_message_build
    person = Person.build(name: "Jane") do |pb|
      pb.address { pb.street "x" }
      pb.name "June"
    end
    assert_equal Person.new(name: "June", address: {street: "x"}), person
    assert_equal Person.new(name: "Jane"), Person.build(name: "Jane")
    assert_equal Person.new(id: 1), Person.build({"id" => 1})
    assert_equal Person.new, Person.build
  end

  def test_field_methods_return_the_builder
    pb = Protostar::Builder.new(Person)
    assert_same pb, pb.name("x")
    assert_same pb, pb.address { pb.street "y" }
    assert_same pb, pb.set!(:id, 1)
    assert_same pb, pb.extract!({}, *[])
  end
end
