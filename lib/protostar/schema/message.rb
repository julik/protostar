# frozen_string_literal: true

module Protostar
  module Schema
    # A message type
    class Message < Descriptor
      # @return [File]
      attr_reader :file
      # @return [Message, nil] the enclosing message for a nested type
      attr_reader :containing_message
      # @return [Array<Field>] declaration order, oneof members included, extensions excluded
      attr_reader :fields
      # @return [Hash{Integer => Field}]
      attr_reader :fields_by_number
      # @return [Hash{String => Field}]
      attr_reader :fields_by_name
      # @return [Hash{String => Field}]
      attr_reader :fields_by_json_name
      # @return [Array<Oneof>] all oneofs, synthetic ones included
      attr_reader :oneofs
      # @return [Array<Oneof>] oneofs that are not synthetic (proto3 `optional`)
      attr_reader :real_oneofs
      # @return [Array<Message>]
      attr_reader :nested_messages
      # @return [Array<Enum>]
      attr_reader :nested_enums
      # @return [Array<Field>] extensions declared inside this message
      attr_reader :extensions
      # @return [Array<ExtensionRange>]
      attr_reader :extension_range_descriptors
      # @return [Array<Range>] inclusive extension number ranges
      attr_reader :extension_ranges
      # @return [Array<Range>] inclusive reserved number ranges
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
      def __members(fields:, oneofs:, nested_messages:, nested_enums:, extensions:, extension_range_descriptors:)
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

      # @param key [Integer, String, Symbol] a field number or name
      # @return [Field, nil]
      def field(key)
        key.is_a?(Integer) ? @fields_by_number[key] : @fields_by_name[key.to_s]
      end

      # @return [Boolean] whether the number falls in an extension range
      def extension_number?(number)
        @extension_ranges.any? { |r| r.cover?(number) }
      end

      # @return [Boolean] a synthesized `map<K, V>` entry type
      def map_entry?
        options.map_entry?
      end

      # @return [Boolean]
      def message_set_wire_format?
        options.message_set_wire_format?
      end
    end
  end
end
