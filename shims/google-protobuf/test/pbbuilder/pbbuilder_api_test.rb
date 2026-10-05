# frozen_string_literal: true

require "test/unit"

# pbbuilder (cheddar-me/pbbuilder) requires only message_exts and patches
# ClassMethods before any message class exists
require "google/protobuf/message_exts"

module Google::Protobuf::MessageExts::ClassMethods
  def pbshim_build(fields = {})
    message = new(fields)
    yield message if block_given?
    message
  end
end

$LOAD_PATH.unshift(File.join(__dir__, "generated"))
require "person_pb"

# Every Google::Protobuf call pbbuilder's lib/ makes, as it makes them
# (pbbuilder.rb and pbbuilder/protobuf_extension.rb); WS9 runs pbbuilder's
# own suite
class PbbuilderApiTest < Test::Unit::TestCase
  Person = Pbshim::Person
  Asset = Pbshim::Asset

  def descriptor_for(message, field)
    message.class.descriptor.lookup(field.to_s)
  end

  def new_message_from_descriptor(descriptor)
    descriptor.subtype.msgclass.new
  end

  def test_class_methods_patched_into_message_exts
    person = Person.pbshim_build(name: "Hello") { |p| p.best_friend = Person.new(name: "Johnny") }
    assert_equal "Hello", person.name
    assert_equal "Johnny", person.best_friend.name
    assert_equal "", Person.pbshim_build.name
    assert_kind_of Google::Protobuf::MessageExts, person
  end

  def test_descriptor_lookup_type_label_and_subtype
    person = Person.new
    assert_nil descriptor_for(person, :nope)
    name = descriptor_for(person, "name")
    assert_equal :string, name.type
    assert_equal :optional, name.label
    assert_nil name.subtype
    friends = descriptor_for(person, :friends)
    assert_equal :message, friends.type
    assert_equal :repeated, friends.label
    assert_equal Person, friends.subtype.msgclass
    assert_equal :repeated, descriptor_for(person, :nicknames).label
    assert_equal :message, descriptor_for(person, :favourite_foods).type
    assert_equal :repeated, descriptor_for(person, :favourite_foods).label
    assert_equal Google::Protobuf::FieldMask, descriptor_for(person, :field_mask).subtype.msgclass
  end

  def test_singular_message_with_block
    person = Person.new
    descriptor = descriptor_for(person, :best_friend)
    message = (person["best_friend"] ||= new_message_from_descriptor(descriptor))
    message["name"] = "Johnny"
    assert_same message, person["best_friend"]
    assert_equal "Johnny", person.best_friend.name
  end

  def test_repeated_messages_pushed
    person = Person.new
    descriptor = descriptor_for(person, :friends)
    elements = %w[a b].map do |name|
      friend = new_message_from_descriptor(descriptor)
      friend["name"] = name
      friend
    end
    person["friends"].push(*elements)
    assert_equal %w[a b], person.friends.map(&:name)
  end

  def test_repeated_scalars_replaced_from_to_ary
    person = Person.new
    person["nicknames"].replace %w[x y].to_ary
    assert_equal %w[x y], person.nicknames.to_a
    person["tags"].replace ["single"]
    assert_equal ["single"], person.tags.to_a
  end

  def test_repeated_messages_replaced_from_messages_and_hashes
    person = Person.new
    descriptor = descriptor_for(person, :friends)
    given = [Person.new(name: "Johnny Test"), {name: "Max Verstappen"}]
    nested = given.map do |member|
      member.is_a?(descriptor.subtype.msgclass) ? member : descriptor.subtype.msgclass.new(member)
    end
    person["friends"].replace(nested)
    assert_same given.first, person.friends.first
    assert_equal ["Johnny Test", "Max Verstappen"], person.friends.map(&:name)
  end

  def test_map_entries_set_from_to_hash
    person = Person.new
    {"pizza" => "yes", "broccoli" => "no"}.to_hash.each { |k, v| person["favourite_foods"][k] = v }
    assert_equal({"pizza" => "yes", "broccoli" => "no"}, person.favourite_foods.to_h)
  end

  def test_merge_with_messages_scalars_and_maps
    person = Person.new
    {"name" => "Merged", "logo" => {url: "a.png"}, "nicknames" => ["n"], "assets" => {"x" => Asset.new(url: "x.png")}}.each do |key, value|
      descriptor = descriptor_for(person, key)
      if descriptor.label == :repeated
        if value.respond_to?(:to_hash)
          value.to_hash.each { |k, v| person[key.to_s][k] = v }
        else
          person[key.to_s].replace(value.map { |obj| descriptor.subtype ? descriptor.subtype.msgclass.new(obj) : obj })
        end
      elsif descriptor.type == :message
        person[key.to_s] = descriptor.subtype.msgclass.new(value)
      else
        person[key.to_s] = value
      end
    end
    assert_equal "Merged", person.name
    assert_equal "a.png", person.logo.url
    assert_equal ["n"], person.nicknames.to_a
    assert_equal "x.png", person.assets["x"].url
  end

  def test_map_field_subtype_has_a_message_class
    descriptor = descriptor_for(Person.new, :assets)
    entry = new_message_from_descriptor(descriptor)
    assert_equal "pbshim.Person.AssetsEntry", entry.class.descriptor.name
    entry.key = "k"
    entry.value = Asset.new(url: "u")
    assert_equal({key: "k", value: {url: "u"}}, entry.to_h)
  end

  def test_attributes_and_extract
    person = Person.new
    source = Struct.new(:name, :boolean_me).new("Ada", true)
    %i[name boolean_me].each { |attr| person[attr.to_s] = source.send(attr) }
    assert_equal({name: "Ada", boolean_me: true}, person.to_h)
  end

  def test_unknown_field_assignment_raises
    assert_raises(ArgumentError) { Person.new["nope"] = 1 }
  end
end
