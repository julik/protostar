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

  # Editions, for the streaming tests: a delimited (group-encoded) message
  # field, a chain of nested messages, packed and expanded repeated scalars
  STREAMING_PROTO = <<~PROTO
    edition = "2023";
    package streamtest;

    message Node {
      string text = 1;
      Node child = 2;
      repeated string lines = 3;
      repeated int32 nums = 4;
      repeated Node kids = 5;
      map<string, Node> named = 6;
      oneof pick {
        Node left = 7;
        string right = 8;
      }
      Node flat = 9 [features.message_encoding = DELIMITED];
    }

    message Root {
      repeated string lines = 1;
      Node node = 2;
      repeated Node nodes = 3;
      Node flat = 4 [features.message_encoding = DELIMITED];
      repeated int32 nums = 5;
      repeated int32 loose = 6 [features.repeated_field_encoding = EXPANDED];
      string name = 7;
    }
  PROTO

  STREAMING = begin
    files = Protostar::Compiler.new.compile(["streamtest.proto"], sources: {"streamtest.proto" => STREAMING_PROTO})
    registry = Protostar::Types::Registry.new
    files.each_with_object({}) { |f, h| h.merge!(registry.define(f)) }.freeze
  end

  Root = STREAMING.fetch("streamtest.Root")
  Node = STREAMING.fetch("streamtest.Node")
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

  module_function

  # Writes a field hash as a template would: field methods where the builder
  # has them, set! where it does not, blocks for nested and repeated messages
  def replay(pb, klass, hash)
    hash.each do |name, value|
      info = klass.__by_name.fetch(name)
      if info.message? && !info.map && info.repeated
        call(pb, name, value) { |h| replay(pb, info.message_class, h) }
      elsif info.message? && !info.map
        call(pb, name) { replay(pb, info.message_class, value) }
      else
        call(pb, name, value)
      end
    end
  end

  def call(pb, name, *args, &block)
    if pb.class.public_method_defined?(name, false)
      pb.public_send(name, *args, &block)
    else
      pb.set!(name, *args, &block)
    end
  end
end
