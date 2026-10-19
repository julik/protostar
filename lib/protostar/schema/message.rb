# frozen_string_literal: true

module Protostar
  module Schema
    # A message type
    class Message < Descriptor
      attr_reader :file #: File
      # The enclosing message for a nested type.
      attr_reader :containing_message #: Message?
      # Declaration order, oneof members included, extensions excluded.
      attr_reader :fields #: Array[Field]
      attr_reader :fields_by_number #: Hash[Integer, Field]
      attr_reader :fields_by_name #: Hash[String, Field]
      attr_reader :fields_by_json_name #: Hash[String, Field]
      # All oneofs, synthetic ones included.
      attr_reader :oneofs #: Array[Oneof]
      # Oneofs that are not synthetic (proto3 `optional`).
      attr_reader :real_oneofs #: Array[Oneof]
      attr_reader :nested_messages #: Array[Message]
      attr_reader :nested_enums #: Array[Enum]
      # Extensions declared inside this message.
      attr_reader :extensions #: Array[Field]
      attr_reader :extension_range_descriptors #: Array[ExtensionRange]
      # Inclusive extension number ranges.
      attr_reader :extension_ranges #: Array[Range[untyped]]
      # Inclusive reserved number ranges.
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

      def __members(fields:, oneofs:, nested_messages:, nested_enums:, extensions:, extension_range_descriptors:) # :nodoc:
        @fields = fields
        @oneofs = oneofs
        @real_oneofs = oneofs.reject(&:synthetic?).freeze
        @nested_messages = nested_messages
        @nested_enums = nested_enums
        @extensions = extensions
        @extension_range_descriptors = extension_range_descriptors
        @extension_ranges = extension_range_descriptors.map(&:range).freeze
        @fields_by_number = {}
        @fields_by_name = {}
        @fields_by_json_name = {}
        fields.each do |f|
          @fields_by_number[f.number] ||= f
          @fields_by_name[f.name] ||= f
          @fields_by_json_name[f.json_name] ||= f
        end
        @fields_by_number.freeze
        @fields_by_name.freeze
        @fields_by_json_name.freeze
        self
      end

      # - `key`: a field number or name
      #: (Integer | String | Symbol key) -> Field?
      def field(key)
        key.is_a?(Integer) ? @fields_by_number[key] : @fields_by_name[key.to_s]
      end

      # Returns whether the number falls in an extension range.
      #: (untyped number) -> bool
      def extension_number?(number)
        @extension_ranges.any? { |r| r.cover?(number) }
      end

      # Returns a synthesized `map<K, V>` entry type.
      #: () -> bool
      def map_entry?
        options.map_entry?
      end

      #: () -> bool
      def message_set_wire_format?
        options.message_set_wire_format?
      end

      # - `default_json_names`: see File#to_proto
      #: (?default_json_names: bool) -> Protostar::Google::Protobuf::DescriptorProto
      def to_proto(default_json_names: true)
        Proto::Writer.message(self, default_json_names)
      end
    end
  end
end
