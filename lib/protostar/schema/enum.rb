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
      # @return [Symbol, nil] declared `visibility`
      attr_reader :visibility

      # @api private
      def initialize(name:, full_name:, file:, containing_message:, index:, options:, reserved_ranges:,
        reserved_names:, visibility:)
        @name = name
        @full_name = full_name
        @file = file
        @containing_message = containing_message
        @index = index
        @options = options
        @reserved_ranges = reserved_ranges
        @reserved_names = reserved_names
        @visibility = visibility
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
        options[:allow_alias] == true
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

      # @return [Hash] the EnumDescriptorProto hash
      def to_h
        h = {name: @name}
        h[:value] = @values.map(&:to_h) unless @values.empty?
        options_to_h(h)
        h[:reserved_range] = @reserved_ranges.map { |r| {start: r.begin, end: r.end} } unless @reserved_ranges.empty?
        h[:reserved_name] = @reserved_names unless @reserved_names.empty?
        h[:visibility] = @visibility if @visibility
        h
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
      def initialize(name:, full_name:, number:, enum:, index:, options:)
        @name = name
        @full_name = full_name
        @number = number
        @enum = enum
        @index = index
        @options = options
      end

      # @return [File]
      def file
        @enum.file
      end

      # @return [Hash] the EnumValueDescriptorProto hash
      def to_h
        options_to_h({name: @name, number: @number})
      end
    end
  end
end
