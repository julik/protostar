# frozen_string_literal: true

require "test_helper"

# Klass.reflection: fields by descriptor, name or number, with the accessors' semantics
class ReflectionTest < Minitest::Test
  def setup
    pool = Protostar::Schema::Pool.new
    file = SchemaFixtures.add(pool, "reflect.proto", package: "reflect", syntax: :proto3) do |f|
      f.enum("Kind") do |e|
        e.value "KIND_UNSPECIFIED", 0
        e.value "KIND_A", 1
      end
      f.message("Address") { |m| m.field "city", 1, :string }
      f.message("Person") do |m|
        m.field "name", 1, :string
        m.field "id", 2, :int32
        m.field "emails", 3, :string, label: :repeated
        m.field "address", 4, "Address"
        m.field "kind", 5, "Kind"
        m.field "nick", 6, :string, optional: true
        m.oneof("contact") do |o|
          o.field "phone", 7, :string
          o.field "fax", 8, :string
        end
        m.map "labels", 9, key: :string, value: "Address"
        m.field "class", 10, :string
      end
    end
    @types = Protostar::Types::Registry.new.define(file)
    @person = @types.fetch("reflect.Person")
    @r = @person.reflection
  end

  def test_describes_the_class
    assert_kind_of Protostar::Message::Reflection, @r
    assert_same @person, @r.klass
    assert_equal "reflect.Person", @r.descriptor.full_name
    assert_equal %w[name id emails address kind nick phone fax labels class], @r.fields.map(&:name)
    assert_equal ["contact"], @r.oneofs.map(&:name)
    assert_same @r.descriptor.field("id"), @r.field(:id)
    assert_same @r.field("id"), @r.field(2)
    assert_same @r.field(2), @r.field(@r.descriptor.field(2))
    assert_nil @r.field(:nope)
    assert Ractor.shareable?(@r)
    assert_equal "#<Protostar::Message::Reflection reflect.Person>", @r.inspect
  end

  def test_reads_and_writes_like_the_accessors
    m = @person.new(name: "Ada")
    assert_equal "Ada", @r.get(m, :name)
    assert_equal 0, @r.get(m, "id")
    @r.set(m, 2, 7)
    assert_equal 7, m.id
    @r.set(m, :class, "x")
    assert_equal "x", m[:class]
    assert_raises(Protostar::TypeError) { @r.set(m, :id, "seven") }
    assert_raises(ArgumentError) { @r.get(m, :nope) }
    @r.clear(m, :name)
    assert_equal "", m.name
  end

  def test_presence
    m = @person.new
    refute @r.set?(m, :name)
    refute @r.set?(m, :emails)
    refute @r.set?(m, :nick)
    m.nick = ""
    assert @r.set?(m, :nick), "explicit presence counts an empty string"
    m.name = "x"
    m.emails << "a"
    assert @r.set?(m, :name)
    assert @r.set?(m, :emails)
    assert_equal %w[name emails nick], @r.each(m).map { |f, _| f.name }
    assert_equal ["x", ["a"], ""], @r.each(m).map { |_, v| v }
  end

  def test_oneofs_and_types
    m = @person.new(phone: "1")
    assert_equal "phone", @r.which(m, :contact).name
    @r.set(m, :fax, "2")
    assert_equal "fax", @r.which(m, @r.oneofs.first).name
    assert_equal "", m.phone
    assert_nil @r.which(@person.new, "contact")
    assert_raises(ArgumentError) { @r.which(m, :nope) }
    address = @types.fetch("reflect.Address")
    assert_same address, @r.message_class(:address)
    assert_same address, @r.message_class(:labels)
    assert_nil @r.message_class(:name)
    assert_same @types.fetch("reflect.Kind"), @r.enum_module(:kind)
    assert_nil @r.enum_module(:id)
  end
end
