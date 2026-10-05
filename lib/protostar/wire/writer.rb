# frozen_string_literal: true

module Protostar
  module Wire
    # Writes wire-format values into a binary String, or through a small
    # buffer straight into an IO.
    #
    #   w = Protostar::Wire::Writer.new
    #   w.write_tag(1, Protostar::Wire::VARINT).write_varint(150)
    #   w.string # => "\x08\x96\x01"
    #
    #   Protostar::Wire::Writer.new(io).write_bytes("hi").flush
    class Writer
      # Bytes buffered before an IO target is written to
      FLUSH_AT = 64 * 1024

      # @return [String] the bytes written so far (for an IO target, those not yet flushed)
      attr_reader :string
      # @return [IO, nil]
      attr_reader :io

      # @param target [String, IO, nil] a String to append to (it is switched
      #   to binary encoding), anything responding to `write`, or nil for a new String
      def initialize(target = nil)
        if target.nil?
          @string = String.new(encoding: BINARY)
          @io = nil
        elsif target.is_a?(String)
          @string = target.force_encoding(BINARY)
          @io = nil
        else
          @string = String.new(capacity: FLUSH_AT, encoding: BINARY)
          @io = target
        end
      end

      # @param value [Integer] negative values are written as ten-byte two's complement
      # @return [self]
      def write_varint(value)
        buf = @string
        if value < 0x80 && value >= 0
          buf << value
          return self
        end
        value &= MASK64 if value < 0
        while value >= 0x80
          buf << ((value & 0x7F) | 0x80)
          value >>= 7
        end
        buf << value
        self
      end

      # @return [self]
      def write_tag(number, wire_type)
        write_varint((number << 3) | wire_type)
      end

      # @param value [Integer] a signed integer, written zigzag-encoded (sint32, sint64)
      # @return [self]
      def write_zigzag(value)
        write_varint((value << 1) ^ (value >> 63))
      end

      # @return [self]
      def write_fixed32(value)
        [value].pack("V", buffer: @string)
        self
      end

      # @return [self]
      def write_fixed64(value)
        [value].pack("Q<", buffer: @string)
        self
      end

      # @return [self]
      def write_sfixed32(value)
        [value].pack("l<", buffer: @string)
        self
      end

      # @return [self]
      def write_sfixed64(value)
        [value].pack("q<", buffer: @string)
        self
      end

      # @return [self]
      def write_float(value)
        [value].pack("e", buffer: @string)
        self
      end

      # @return [self]
      def write_double(value)
        [value].pack("E", buffer: @string)
        self
      end

      # Writes a varint length followed by the bytes of `value`, whatever its encoding
      # @return [self]
      def write_bytes(value)
        write_varint(value.bytesize)
        write_raw(value)
      end

      if String.method_defined?(:append_as_bytes)
        # Appends the bytes of `value` as they are, whatever its encoding
        # @return [self]
        def write_raw(value)
          @string.append_as_bytes(value)
          flush_if_full
        end
      else
        # Appends the bytes of `value` as they are, whatever its encoding
        # @return [self]
        def write_raw(value)
          # `<<` would raise or re-tag the buffer for a non-ASCII UTF-8 value
          [value].pack("a*", buffer: @string)
          flush_if_full
        end
      end

      # Writes the buffer to the IO target once it holds {FLUSH_AT} bytes
      # @return [self]
      def flush_if_full
        flush if @io && @string.bytesize >= FLUSH_AT
        self
      end

      # Writes whatever is buffered to the IO target. A no-op for a String target.
      # @return [self]
      def flush
        if @io && !@string.empty?
          @io.write(@string)
          @string.clear
        end
        self
      end
    end
  end
end
