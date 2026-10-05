# frozen_string_literal: true

require "google/protobuf/any_pb"
require "google/protobuf/duration_pb"
require "google/protobuf/field_mask_pb"
require "google/protobuf/struct_pb"
require "google/protobuf/timestamp_pb"

# Timestamp (from_time, to_time, to_i, to_f) and Duration (to_f) have their
# helpers from Protostar::WellKnown, which protostar mixes into those classes
# however they are defined. Struct, Value and ListValue get the gem's from
# Google::Protobuf::Internal::WellKnown as their classes are set up, so they
# work without this file too. Any#pack is defined here, returning what the
# gem's does.
module Google
  module Protobuf
    Any.class_eval do
      # @return [Any] a new Any holding the message
      def self.pack(msg, type_url_prefix = "type.googleapis.com/")
        any = new
        any.pack(msg, type_url_prefix)
        any
      end

      # Stores the message and a type URL of the prefix and its full name
      # @return [String] the message's bytes
      def pack(msg, type_url_prefix = "type.googleapis.com/")
        self.type_url = if type_url_prefix.empty? || !type_url_prefix.end_with?("/")
          "#{type_url_prefix}/#{msg.class.descriptor.name}"
        else
          "#{type_url_prefix}#{msg.class.descriptor.name}"
        end
        self.value = msg.to_proto
      end
    end
  end
end
