# frozen_string_literal: true

module Protostar
  module Wire
    # Presents an IO::Buffer with the String methods Reader uses, so that
    # a buffer is read in place: numbers with `get_value`, and only string
    # and bytes values copied out, with `get_string`.
    class IOSource
      # unpack1 directives the codec uses, as IO::Buffer data types
      TYPES = {"V" => :u32, "Q<" => :u64, "l<" => :s32, "q<" => :s64, "e" => :f32, "E" => :f64}.freeze

      attr_reader :buffer #: IO::Buffer
      attr_reader :bytesize #: Integer

      # - `buffer`: must not change while it is read
      #: (IO::Buffer buffer) -> void
      def initialize(buffer)
        @buffer = buffer
        @bytesize = buffer.size
        freeze
      end

      #: (untyped offset) -> Integer
      def getbyte(offset)
        @buffer.get_value(:U8, offset)
      end

      # Returns a new binary String.
      #: (untyped offset, untyped length) -> String
      def byteslice(offset, length)
        @buffer.get_string(offset, length)
      end

      # - `format`: one of the directives in TYPES
      #: (String format, offset: untyped) -> untyped
      def unpack1(format, offset:)
        @buffer.get_value(TYPES.fetch(format), offset)
      end
    end
  end
end
