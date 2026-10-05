# frozen_string_literal: true

module Protostar
  module Schema
    # A oneof, real or synthesized for a proto3 `optional` field
    class Oneof < Descriptor
      # @return [Message]
      attr_reader :containing_message
      # @return [Array<Field>] members in declaration order
      attr_reader :fields

      # @api private
      def initialize(name:, full_name:, containing_message:, index:, options:)
        @name = name
        @full_name = full_name
        @containing_message = containing_message
        @index = index
        @options = options
        @fields = []
        @synthetic = false
      end

      # @return [File]
      def file
        @containing_message.file
      end

      # @return [Boolean] whether protoc synthesized it for a proto3 `optional` field
      def synthetic?
        @synthetic
      end

      # @return [Hash] the OneofDescriptorProto hash
      def to_h
        options_to_h({name: @name})
      end
    end
  end
end
