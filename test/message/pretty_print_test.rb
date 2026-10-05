# frozen_string_literal: true

require "test_helper"
require "pp"

class PrettyPrintTest < Minitest::Test
  PROTO = <<~PROTO
    syntax = "proto3";
    package pptest;
    message Address { string street = 1; string city = 2; }
    message Person {
      string name = 1;
      Address home = 2;
      repeated Address others = 3;
      repeated int32 ids = 4;
      int32 age = 5;
    }
  PROTO

  TYPES = begin
    files = Protostar::Compiler.new.compile(["pptest.proto"], sources: {"pptest.proto" => PROTO})
    Protostar::Types::Registry.new.define(files.last)
  end
  Person = TYPES.fetch("pptest.Person")

  def person
    Person.new(
      name: "Ada Lovelace",
      home: {street: "12 St James's Square", city: "London"},
      others: [{city: "Paris"}, {city: "Turin"}],
      ids: [1, 2]
    )
  end

  def pp(object, width = 79)
    PP.pp(object, +"", width)
  end

  def test_a_message_that_fits_prints_as_inspect
    small = Person.new(name: "Ada", ids: [1])
    assert_equal "#{small.inspect}\n", pp(small)
    assert_equal "#<pptest.Person>\n", pp(Person.new)
  end

  def test_a_long_message_has_one_field_per_line_and_nested_messages_indented
    assert_equal <<~PP, pp(person)
      #<pptest.Person
        name: "Ada Lovelace",
        home: #<pptest.Address street: "12 St James's Square", city: "London">,
        others: [#<pptest.Address city: "Paris">, #<pptest.Address city: "Turin">],
        ids: [1, 2]>
    PP
    assert_equal <<~PP, pp(person, 40)
      #<pptest.Person
        name: "Ada Lovelace",
        home: #<pptest.Address
          street: "12 St James's Square",
          city: "London">,
        others: [#<pptest.Address
           city: "Paris">,
         #<pptest.Address city: "Turin">],
        ids: [1, 2]>
    PP
  end

  def test_views_print_the_same_way
    view = Person.view(person.encode)
    assert_equal <<~PP, pp(view, 40)
      #<view pptest.Person
        name: "Ada Lovelace",
        home: #<view pptest.Address
          street: "12 St James's Square",
          city: "London">,
        others: [#<view pptest.Address
           city: "Paris">,
         #<view pptest.Address
           city: "Turin">],
        ids: [1, 2]>
    PP
    assert_equal "#{view.inspect}\n", pp(view, 500)
  end
end
