# frozen_string_literal: true

module Protostar
  module Wire
    # Reads wire-format values from a String without copying it or allocating
    # per byte. The String is never mutated, and its encoding does not matter:
    # every read works on bytes.
    #
    # A reader has a position and a limit. Reads never go past the limit, so a
    # nested message is read by narrowing the limit to its end and restoring it
    # afterwards ({#push_limit}, {#pop_limit}).
    #
    #   r = Protostar::Wire::Reader.new(bytes)
    #   until r.eof?
    #     number, wire_type = r.read_tag
    #     ...
    #   end
    class Reader
      # @return [String] the underlying bytes
      attr_reader :buffer
      # @return [Integer] the current byte offset
      attr_accessor :pos
      # @return [Integer] the offset reads must not pass
      attr_reader :limit

      # @param buffer [String, IO::Buffer] an IO::Buffer is copied into a String once
      # @param pos [Integer] where to start
      # @param limit [Integer, nil] where to stop, the end of the buffer by default
      def initialize(buffer, pos = 0, limit = nil)
        buffer = buffer.get_string if defined?(IO::Buffer) && buffer.is_a?(IO::Buffer)
        raise ::TypeError, "expected a String or IO::Buffer, got #{buffer.class}" unless buffer.is_a?(String)
        @buffer = buffer
        @pos = pos
        @limit = limit || buffer.bytesize
        raise ArgumentError, "limit #{@limit} is past the end of the buffer" if @limit > buffer.bytesize
      end

      # @return [Boolean] whether the position has reached the limit
      def eof?
        @pos >= @limit
      end

      # Narrows the limit to `length` bytes from the current position
      # @return [Integer] the previous limit, to hand to {#pop_limit}
      # @raise [DecodeError] when that runs past the current limit
      def push_limit(length)
        new_limit = @pos + length
        raise DecodeError.new("length #{length} runs past the end of the input", offset: @pos) if new_limit > @limit
        old = @limit
        @limit = new_limit
        old
      end

      # Restores a limit returned by {#push_limit}
      def pop_limit(old_limit)
        @limit = old_limit
      end

      # @return [Integer] an unsigned varint of up to 64 bits. Longer encodings
      #   are truncated to 64 bits, as protoc does.
      # @raise [DecodeError] when truncated or longer than ten bytes
      def read_varint
        pos = @pos
        raise DecodeError.new("truncated varint", offset: pos) if pos >= @limit
        byte = @buffer.getbyte(pos)
        if byte < 0x80
          @pos = pos + 1
          return byte
        end
        read_varint_slow(pos)
      end

      # @return [Array(Integer, Integer)] field number and wire type
      # @raise [DecodeError] for field number 0, an out of range tag or an invalid wire type
      def read_tag
        at = @pos
        tag = read_varint
        Reader.check_tag(tag, at)
        [tag >> 3, tag & 7]
      end

      # @return [Integer] a signed 32-bit integer from a varint (int32 and enum)
      def read_int32
        v = read_varint & MASK32
        (v >= 0x8000_0000) ? v - 0x1_0000_0000 : v
      end

      # @return [Integer] a signed 64-bit integer from a varint
      def read_int64
        v = read_varint
        (v >= 0x8000_0000_0000_0000) ? v - 0x1_0000_0000_0000_0000 : v
      end

      # @return [Integer] an unsigned 32-bit integer from a varint
      def read_uint32
        read_varint & MASK32
      end

      # @return [Integer] a zigzag-decoded signed 32-bit integer (sint32)
      def read_sint32
        v = read_varint & MASK32
        (v >> 1) ^ -(v & 1)
      end

      # @return [Integer] a zigzag-decoded signed 64-bit integer (sint64)
      def read_sint64
        v = read_varint
        (v >> 1) ^ -(v & 1)
      end

      # @return [Integer] an unsigned 32-bit little-endian integer
      def read_fixed32
        read_fixed(4, "V")
      end

      # @return [Integer] an unsigned 64-bit little-endian integer
      def read_fixed64
        read_fixed(8, "Q<")
      end

      # @return [Integer]
      def read_sfixed32
        read_fixed(4, "l<")
      end

      # @return [Integer]
      def read_sfixed64
        read_fixed(8, "q<")
      end

      # @return [Float]
      def read_float
        read_fixed(4, "e")
      end

      # @return [Float]
      def read_double
        read_fixed(8, "E")
      end

      # Reads a varint length and that many bytes
      # @return [String] a new binary String
      def read_bytes
        len = read_varint
        read_raw(len)
      end

      # @return [String] the next `length` bytes as a new binary String
      def read_raw(length)
        pos = @pos
        raise DecodeError.new("length #{length} runs past the end of the input", offset: pos) if pos + length > @limit
        @pos = pos + length
        s = @buffer.byteslice(pos, length)
        s.force_encoding(BINARY)
      end

      # Skips the value of a field whose tag was just read
      # @param number [Integer] the field number, needed to match the end of a group
      # @param wire_type [Integer]
      # @param depth [Integer] groups left before {DecodeError} for nesting too deep
      def skip_field(number, wire_type, depth = 100)
        case wire_type
        when VARINT then read_varint
        when FIXED64 then skip(8)
        when LENGTH_DELIMITED then skip(read_varint)
        when FIXED32 then skip(4)
        when START_GROUP then skip_group(number, depth)
        when END_GROUP then raise DecodeError.new("unmatched end of group #{number}", offset: @pos)
        else raise DecodeError.new("invalid wire type #{wire_type}", offset: @pos)
        end
        nil
      end

      # @raise [DecodeError] unless `length` bytes remain before the limit
      def skip(length)
        raise DecodeError.new("length #{length} runs past the end of the input", offset: @pos) if @pos + length > @limit
        @pos += length
      end

      # Skips the contents of a group up to and including its end tag
      def skip_group(number, depth = 100)
        raise DecodeError.new("groups nested too deep", offset: @pos) if depth <= 0
        loop do
          raise DecodeError.new("missing end of group #{number}", offset: @pos) if @pos >= @limit
          at = @pos
          tag = read_varint
          Reader.check_tag(tag, at)
          n = tag >> 3
          wt = tag & 7
          if wt == END_GROUP
            return if n == number
            raise DecodeError.new("end of group #{n} does not match group #{number}", offset: at)
          end
          skip_field(n, wt, depth - 1)
        end
      end

      # @api private
      def self.check_tag(tag, at)
        raise DecodeError.new("tag out of range", offset: at) if tag > MASK32
        raise DecodeError.new("field number 0", offset: at) if tag < 8
        wt = tag & 7
        raise DecodeError.new("invalid wire type #{wt}", offset: at) if wt > 5
      end

      private

      def read_fixed(size, format)
        pos = @pos
        raise DecodeError.new("truncated #{size * 8}-bit value", offset: pos) if pos + size > @limit
        @pos = pos + size
        @buffer.unpack1(format, offset: pos)
      end

      def read_varint_slow(start)
        buf = @buffer
        limit = @limit
        pos = start
        result = 0
        shift = 0
        while shift < 70
          raise DecodeError.new("truncated varint", offset: start) if pos >= limit
          byte = buf.getbyte(pos)
          pos += 1
          result |= (byte & 0x7F) << shift
          if byte < 0x80
            @pos = pos
            # masking with a Bignum allocates, and only a tenth byte can overflow 64 bits
            return (shift == 63) ? result & MASK64 : result
          end
          shift += 7
        end
        raise DecodeError.new("varint longer than 10 bytes", offset: start)
      end
    end
  end
end
