# frozen_string_literal: true

module Protostar
  module Schema
    # An enum type
    class Enum < Descriptor
      attr_reader :file #: File
      attr_reader :containing_message #: Message?
      # Declaration order.
      attr_reader :values #: Array[EnumValue]
      # The first declared value wins for aliases.
      attr_reader :values_by_number #: Hash[Integer, EnumValue]
      attr_reader :values_by_name #: Hash[String, EnumValue]
      # Inclusive.
      attr_reader :reserved_ranges #: Array[Range[untyped]]
      attr_reader :reserved_names #: Array[String]
      # Declared `visibility`: :local or :export (edition 2024), nil when not declared.
      attr_reader :visibility #: Symbol?

      def initialize(name:, full_name:, file:, containing_message:, index:) # :nodoc:
        @name = name
        @full_name = full_name
        @file = file
        @containing_message = containing_message
        @index = index
        @reserved_ranges = Freezer::EMPTY_ARRAY
        @reserved_names = Freezer::EMPTY_ARRAY
        @visibility = nil
      end

      def __values(values) # :nodoc:
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

      # - `key`: a value number or name
      #: (Integer | String | Symbol key) -> EnumValue?
      def value(key)
        key.is_a?(Integer) ? @values_by_number[key] : @values_by_name[key.to_s]
      end

      #: () -> bool
      def allow_alias?
        options.allow_alias?
      end

      # Whether unknown numbers go to unknown fields (proto2, editions
      # `enum_type = CLOSED`) instead of being kept in the field (proto3, `OPEN`).
      #: () -> bool
      def closed?
        @features.enum_type == :CLOSED
      end

      #: () -> bool
      def open?
        !closed?
      end

      #: () -> Protostar::Google::Protobuf::EnumDescriptorProto
      def to_proto
        Proto::Writer.enum(self)
      end
    end

    # A value of an enum. Its #full_name lives in the enum's enclosing scope,
    # as in protoc: value `FOO` of `pkg.Color` is `pkg.FOO`.
    class EnumValue < Descriptor
      attr_reader :number #: Integer
      attr_reader :enum #: Enum

      def initialize(name:, full_name:, number:, enum:, index:) # :nodoc:
        @name = name
        @full_name = full_name
        @number = number
        @enum = enum
        @index = index
      end

      #: () -> File
      def file
        @enum.file
      end

      #: () -> Protostar::Google::Protobuf::EnumValueDescriptorProto
      def to_proto
        Proto::Writer.enum_value(self)
      end
    end
  end
end
