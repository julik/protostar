# frozen_string_literal: true

require "test_helper"

# The schema the builder tests write, compiled once into a registry of its own
module BuilderSupport
  PROTO = <<~PROTO
    syntax = "proto3";
    package buildertest;
    import "google/protobuf/timestamp.proto";
    import "google/protobuf/duration.proto";
    import "google/protobuf/wrappers.proto";

    enum Kind {
      KIND_UNSPECIFIED = 0;
      KIND_A = 1;
      KIND_B = 2;
    }

    message Address {
      string street = 1;
      string city = 2;
    }

    message Person {
      string name = 1;
      int32 id = 2;
      Address address = 3;
      repeated Person friends = 4;
      repeated string nicknames = 5;
      map<string, string> attrs = 6;
      map<int32, Address> places = 7;
      google.protobuf.Timestamp created_at = 8;
      google.protobuf.Duration ttl = 9;
      google.protobuf.StringValue maybe_name = 10;
      Kind kind = 11;
      oneof contact {
        string email = 12;
        string phone = 13;
        Address postal = 14;
      }
      optional int32 score = 15;
      bytes avatar = 16;
      double weight = 17;
      float ratio = 18;
      sint64 delta = 19;
      fixed32 crc = 20;
      bool active = 21;
      string format = 22;
      repeated Address homes = 23;
      google.protobuf.Int64Value big = 24;
      repeated Kind kinds = 30;
      repeated int32 ids = 31;
      repeated double scores = 32;
      repeated sint32 deltas = 33;
      repeated bool flags = 34;
    }
  PROTO

  TYPES = begin
    files = Protostar::Compiler.new.compile(["buildertest.proto"], sources: {"buildertest.proto" => PROTO})
    registry = Protostar::Types::Registry.new
    files.each_with_object({}) { |f, h| h.merge!(registry.define(f)) }.freeze
  end

  Person = TYPES.fetch("buildertest.Person")
  Address = TYPES.fetch("buildertest.Address")
  Timestamp = TYPES.fetch("google.protobuf.Timestamp")
  Duration = TYPES.fetch("google.protobuf.Duration")

  # A cache store with the three methods Rails.cache has that the builder uses
  class Store
    attr_reader :data, :fetches

    def initialize
      @data = {}
      @fetches = []
    end

    def read(key, _options = nil)
      @data[key]
    end

    def write(key, value, _options = nil)
      @data[key] = value
    end

    def fetch(key, options = nil)
      @fetches << [key, options]
      @data.key?(key) ? @data[key] : write(key, yield, options)
    end
  end

  def build(klass = Person, **options, &block)
    Protostar::Builder.build(klass, **options, &block)
  end

  def decode(bytes, klass = Person)
    klass.decode(bytes)
  end
end
