# frozen_string_literal: true

module Protostar
  module Wire
    # Presents an IO::Buffer with the String methods {Reader} uses, so that
    # a buffer is read in place: numbers with `get_value`, and only string
    # and bytes values copied out, with `get_string`.
    class IOSource
      # unpack1 directives the codec uses, as IO::Buffer data types
      TYPES = {"V" => :u32, "Q<" => :u64, "l<" => :s32, "q<" => :s64, "e" => :f32, "E" => :f64}.freeze

      # @return [IO::Buffer]
      attr_reader :buffer
      # @return [Integer]
      attr_reader :bytesize

      # @param buffer [IO::Buffer] must not change while it is read
      def initialize(buffer)
        @buffer = buffer
        @bytesize = buffer.size
        freeze
      end

      # @return [Integer]
      def getbyte(offset)
        @buffer.get_value(:U8, offset)
      end

      # @return [String] a new binary String
      def byteslice(offset, length)
        @buffer.get_string(offset, length)
      end

      # @param format [String] one of the directives in {TYPES}
      def unpack1(format, offset:)
        @buffer.get_value(TYPES.fetch(format), offset)
      end
    end
  end
end
