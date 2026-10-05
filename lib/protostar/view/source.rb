# frozen_string_literal: true

module Protostar
  class View
    # A {Wire::Reader} over any buffer that answers `getbyte`, `byteslice`,
    # `unpack1(format, offset:)` and `bytesize`: a String, or an {IOSource}.
    # The eager decoder runs on it unchanged, which is how {View#to_message}
    # decodes an IO::Buffer without copying it whole.
    # @api private
    class Cursor < Wire::Reader
      attr_writer :limit

      def initialize(buffer, limit)
        @buffer = buffer
        @pos = 0
        @limit = limit
      end
    end

    # Presents an IO::Buffer with the String methods the scanner and the
    # decoder use. Numbers are read in place with `get_value`; only string
    # and bytes values are copied out, with `get_string`.
    # @api private
    class IOSource
      # unpack1 directives the codec uses, as IO::Buffer data types
      TYPES = {"V" => :u32, "Q<" => :u64, "l<" => :s32, "q<" => :s64, "e" => :f32, "E" => :f64}.freeze

      # @return [IO::Buffer]
      attr_reader :buffer
      # @return [Integer]
      attr_reader :bytesize

      def initialize(buffer)
        @buffer = buffer
        @bytesize = buffer.size
        freeze
      end

      def getbyte(offset)
        @buffer.get_value(:U8, offset)
      end

      def byteslice(offset, length)
        @buffer.get_string(offset, length)
      end

      def unpack1(format, offset:)
        @buffer.get_value(TYPES.fetch(format), offset)
      end
    end
  end
end
