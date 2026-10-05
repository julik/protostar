# frozen_string_literal: true

require "protostar"
require "google/protobuf/message_exts"

module Google
  # google-protobuf's Ruby API on top of protostar. Generated `_pb.rb` files
  # written by protoc (or `protostar compile --google_out`) load unchanged.
  module Protobuf
    class Error < StandardError; end

    class ParseError < Error; end

    class TypeError < ::TypeError; end

    # Raised by Struct, Value and ListValue for a Ruby value they cannot hold
    class UnexpectedStructType < Error; end

    # The gem chooses between its C extension and FFI here; there is only protostar
    PREFER_FFI = false

    # @return [Symbol] which implementation is loaded
    IMPLEMENTATION = :PROTOSTAR

    # @return [String] the message's binary encoding
    def self.encode(msg, options = {})
      msg.to_proto(options)
    end

    # @return [String] the message as JSON
    def self.encode_json(msg, options = {})
      msg.to_json(options)
    end

    # @return [Message]
    def self.decode(klass, proto, options = {})
      klass.decode(proto, options)
    end

    # @return [Message]
    def self.decode_json(klass, json, options = {})
      klass.decode_json(json, options)
    end

    # @param object [Message, RepeatedField, Map]
    # @return [Message, RepeatedField, Map] a copy with every nested message copied too
    def self.deep_copy(object)
      case object
      when RepeatedField, Map then object.__deep_copy
      when MessageExts then object.__gdeep_copy
      else raise ::TypeError, "wrong argument type #{object.class} (expected Google::Protobuf::Message)"
      end
    end

    # Drops the unknown fields of a message and of every message in it
    # (extensions stay)
    # @return [nil]
    def self.discard_unknown(message)
      raise FrozenError if message.frozen?
      raise ArgumentError, "Expected message, got #{message.class} instead." unless message.is_a?(MessageExts)
      Internal.discard_unknown(message)
      nil
    end

    module Internal
      # @api private
      def self.discard_unknown(message)
        descriptor = message.class.descriptor.__schema
        kept = message.unknown_fields.select { |u| descriptor.extension_number?(u.number) }
        message.__greplace_unknown(kept) if kept.size != message.unknown_fields.size
        message.class.__fields.each do |info|
          next unless info.map ? info.value.message? : info.message?
          v = message.__values[info.index]
          case v
          when nil then next
          when Hash then v.each_value { |m| discard_unknown(m) }
          when Array then v.each { |m| discard_unknown(m) }
          else discard_unknown(v)
          end
        end
      end
    end
  end
end

require "google/protobuf/internal/convert"
require "google/protobuf/descriptors"
require "google/protobuf/descriptor_pool"
require "google/protobuf/message"
require "google/protobuf/repeated_field"
require "google/protobuf/map"
require "google/protobuf/internal/extensions"
require "google/protobuf/internal/json"

Google::Protobuf::DescriptorPool.instance_variable_set(:@generated_pool, Google::Protobuf::DescriptorPool.new)
