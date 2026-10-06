# frozen_string_literal: true

require_relative "builder_support"

class BuilderRactorTest < Minitest::Test
  include BuilderSupport

  # Ruby 4.0 replaced Ractor#take with Ractor#value
  def in_ractor(*args, &block)
    experimental = Warning[:experimental]
    Warning[:experimental] = false
    ractor = begin
      Ractor.new(*args, &block)
    ensure
      Warning[:experimental] = experimental
    end
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  end

  def test_builder_classes_are_shareable
    assert Ractor.shareable?(Protostar::Builder.for(Person))
  end

  def test_building_in_another_ractor
    Protostar::Builder.for(Person)
    bytes = in_ractor(Person) do |klass|
      Protostar::Builder.build(klass) do |pb|
        pb.name "r"
        pb.friends([1, 2]) { |i| pb.id i }
        pb.attrs("a" => "b")
        pb.ids [1]
      end
    end
    assert_equal Person.new(name: "r", friends: [{id: 1}, {id: 2}], attrs: {"a" => "b"}, ids: [1]).encode, bytes
  end

  def test_a_builder_class_first_needed_in_another_ractor
    # no other test builds this class at the top level
    wrapper = TYPES.fetch("google.protobuf.Int64Value")
    # Builder itself is autoloaded here, which Ruby 3.2 and 3.3 cannot do in another Ractor
    Protostar::Builder.for(Person)
    value, kept = in_ractor(wrapper) do |klass|
      [Protostar::Builder.message(klass) { |pb| pb.value 5 }.value, !klass.instance_variable_get(:@__builder).nil?]
    end
    assert_equal 5, value
    refute kept, "a builder class made in another Ractor is not kept on the message class"
  end
end
