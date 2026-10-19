# frozen_string_literal: true

module Protostar
  module Schema
    # A oneof, real or synthesized for a proto3 `optional` field
    class Oneof < Descriptor
      attr_reader :containing_message #: Message
      # Members in declaration order.
      attr_reader :fields #: Array[Field]

      def initialize(name:, full_name:, containing_message:, index:) # :nodoc:
        @name = name
        @full_name = full_name
        @containing_message = containing_message
        @index = index
        @fields = []
        @synthetic = false
      end

      #: () -> File
      def file
        @containing_message.file
      end

      # Returns whether protoc synthesized it for a proto3 `optional` field.
      #: () -> bool
      def synthetic?
        @synthetic
      end

      #: () -> Protostar::Google::Protobuf::OneofDescriptorProto
      def to_proto
        Proto::Writer.oneof(self)
      end
    end
  end
end
