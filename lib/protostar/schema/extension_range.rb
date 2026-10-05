# frozen_string_literal: true

module Protostar
  module Schema
    # One `extensions` declaration of a message, with its options and features
    class ExtensionRange < Descriptor
      # @return [Message]
      attr_reader :containing_message
      # @return [Range] inclusive
      attr_reader :range

      # @api private
      def initialize(containing_message:, index:, range:)
        @containing_message = containing_message
        @index = index
        @range = range
        @name = "#{range.begin}..#{range.end}"
        @full_name = "#{containing_message.full_name}.extensions(#{@name})"
      end

      # @return [File]
      def file
        @containing_message.file
      end

      # @return [Integer] first extension number, inclusive
      def start
        @range.begin
      end

      # @return [Integer] last extension number, inclusive
      def end
        @range.end
      end
    end
  end
end
