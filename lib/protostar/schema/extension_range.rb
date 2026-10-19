# frozen_string_literal: true

module Protostar
  module Schema
    # One `extensions` declaration of a message, with its options and features
    class ExtensionRange < Descriptor
      attr_reader :containing_message #: Message
      # Inclusive.
      attr_reader :range #: Range[untyped]

      def initialize(containing_message:, index:, range:) # :nodoc:
        @containing_message = containing_message
        @index = index
        @range = range
        @name = "#{range.begin}..#{range.end}"
        @full_name = "#{containing_message.full_name}.extensions(#{@name})"
      end

      #: () -> File
      def file
        @containing_message.file
      end

      # Returns first extension number, inclusive.
      #: () -> Integer
      def start
        @range.begin
      end

      # Returns last extension number, inclusive.
      #: () -> Integer
      def end
        @range.end
      end
    end
  end
end
