# frozen_string_literal: true

module Protostar
  module Schema
    # An enum type
    class Enum < Descriptor
      # @return [File]
      attr_reader :file
      # @return [Message, nil]
      attr_reader :containing_message
      # @return [Array<EnumValue>] declaration order
      attr_reader :values
      # @return [Hash{Integer => EnumValue}] the first declared value wins for aliases
      attr_reader :values_by_number
      # @return [Hash{String => EnumValue}]
      attr_reader :values_by_name
      # @return [Array<Range>] inclusive
      attr_reader :reserved_ranges
      # @return [Array<String>]
      attr_reader :reserved_names
      # @return [Symbol, nil] declared `visibility`: :local or :export (edition 2024), nil when not declared
      attr_reader :visibility

      # @api private
      def initialize(name:, full_name:, file:, containing_message:, index:)
        @name = name
        @full_name = full_name
        @file = file
        @containing_message = containing_message
        @index = index
        @reserved_ranges = Freezer::EMPTY_ARRAY
        @reserved_names = Freezer::EMPTY_ARRAY
        @visibility = nil
      end

      # @api private
      def __values(values)
        @values = values
        @values_by_number = {}
        @values_by_name = {}
        values.each do |v|
          @values_by_number[v.number] ||= v
          @values_by_name[v.name] ||= v
        end
        @values_by_number.freeze
        @values_by_name.freeze
        self
      end

      # @param key [Integer, String, Symbol] a value number or name
      # @return [EnumValue, nil]
      def value(key)
        key.is_a?(Integer) ? @values_by_number[key] : @values_by_name[key.to_s]
      end

      # @return [Boolean]
      def allow_alias?
        options.allow_alias?
      end

      # @return [Boolean] unknown numbers go to unknown fields (proto2, editions
      #   `enum_type = CLOSED`) instead of being kept in the field (proto3, `OPEN`)
      def closed?
        @features.enum_type == :CLOSED
      end

      # @return [Boolean]
      def open?
        !closed?
      end

      # @return [Protostar::Google::Protobuf::EnumDescriptorProto]
      def to_proto
        Proto::Writer.enum(self)
      end
    end

    # A value of an enum. Its {#full_name} lives in the enum's enclosing scope,
    # as in protoc: value `FOO` of `pkg.Color` is `pkg.FOO`.
    class EnumValue < Descriptor
      # @return [Integer]
      attr_reader :number
      # @return [Enum]
      attr_reader :enum

      # @api private
      def initialize(name:, full_name:, number:, enum:, index:)
        @name = name
        @full_name = full_name
        @number = number
        @enum = enum
        @index = index
      end

      # @return [File]
      def file
        @enum.file
      end

      # @return [Protostar::Google::Protobuf::EnumValueDescriptorProto]
      def to_proto
        Proto::Writer.enum_value(self)
      end
    end
  end
end
