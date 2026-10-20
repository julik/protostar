# frozen_string_literal: true

module Protostar
  module Wire
    # Reads wire-format values from a String without copying it or allocating
    # per byte. The String is never mutated, and its encoding does not matter:
    # every read works on bytes. An IO::Buffer is read in place through an
    # IOSource, and so is any source answering `getbyte`, `byteslice`,
    # `unpack1(format, offset:)` and `bytesize` the way String does.
    #
    # A reader has a position and a limit. Reads never go past the limit, so a
    # nested message is read by narrowing the limit to its end and restoring it
    # afterwards (#push_limit, #pop_limit).
    #
    # ```ruby
    # r = Protostar::Wire::Reader.new(bytes)
    # until r.eof?
    #   number, wire_type = r.read_tag
    #   ...
    # end
    # ```
    class Reader
      # What a source other than a String must answer
      SOURCE_METHODS = %i[getbyte byteslice unpack1 bytesize].freeze

      # The underlying bytes.
      attr_reader :buffer #: untyped
      # The current byte offset.
      attr_accessor :pos #: Integer
      # The offset reads must not pass.
      attr_reader :limit #: Integer

      # - `buffer`: an IO::Buffer is wrapped in an IOSource, not copied
      # - `pos`: where to start
      # - `limit`: where to stop, the end of the buffer by default
      #: (untyped buffer, ?Integer pos, ?Integer? limit) -> void
      def initialize(buffer, pos = 0, limit = nil)
        buffer = IOSource.new(buffer) if defined?(IO::Buffer) && buffer.is_a?(IO::Buffer)
        unless buffer.is_a?(String) || SOURCE_METHODS.all? { |m| buffer.respond_to?(m) }
          raise ::TypeError, "expected a String, an IO::Buffer or a source answering #{SOURCE_METHODS.join(", ")}, got #{buffer.class}"
        end
        @buffer = buffer
        @pos = pos
        @limit = limit || buffer.bytesize
        raise ArgumentError, "limit #{@limit} is past the end of the buffer" if @limit > buffer.bytesize
      end

      # Returns whether the position has reached the limit.
      #: () -> bool
      def eof?
        @pos >= @limit
      end

      # Narrows the limit to `length` bytes from the current position
      #
      # Returns the previous limit, to hand to #pop_limit.
      # Raises DecodeError when that runs past the current limit.
      #: (untyped length) -> Integer
      def push_limit(length)
        new_limit = @pos + length
        raise DecodeError.new("length #{length} runs past the end of the input", offset: @pos) if new_limit > @limit
        old = @limit
        @limit = new_limit
        old
      end

      # Restores a limit returned by #push_limit
      def pop_limit(old_limit)
        @limit = old_limit
      end

      # Moves to `pos` with `limit`, unchecked. Generated decoders keep both
      # in locals and hand them back before calling into the reader.
      #: (Integer pos, Integer limit) -> self
      def __seek(pos, limit) # :nodoc:
        @pos = pos
        @limit = limit
        self
      end

      # Returns an unsigned varint of up to 64 bits. Longer encodings
      # are truncated to 64 bits, as protoc does.
      # Raises DecodeError when truncated or longer than ten bytes.
      #: () -> Integer
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

      # Returns a tag's varint, unchecked.
      # Raises DecodeError when truncated or longer than five bytes, which
      # protoc refuses even when the value would fit.
      #: () -> Integer
      def read_tag_varint
        at = @pos
        tag = read_varint
        raise DecodeError.new("tag longer than 5 bytes", offset: at) if @pos - at > 5
        tag
      end

      # Returns field number and wire type.
      # Raises DecodeError for field number 0, an out of range tag or an invalid wire type.
      #: () -> [Integer, Integer]
      def read_tag
        at = @pos
        tag = read_tag_varint
        Reader.check_tag(tag, at)
        [tag >> 3, tag & 7]
      end

      # Returns a signed 32-bit integer from a varint (int32 and enum).
      #: () -> Integer
      def read_int32
        v = read_varint & MASK32
        (v >= 0x8000_0000) ? v - 0x1_0000_0000 : v
      end

      # Returns a signed 64-bit integer from a varint.
      #: () -> Integer
      def read_int64
        v = read_varint
        (v >= 0x8000_0000_0000_0000) ? v - 0x1_0000_0000_0000_0000 : v
      end

      # Returns an unsigned 32-bit integer from a varint.
      #: () -> Integer
      def read_uint32
        read_varint & MASK32
      end

      # Returns a zigzag-decoded signed 32-bit integer (sint32).
      #: () -> Integer
      def read_sint32
        v = read_varint & MASK32
        (v >> 1) ^ -(v & 1)
      end

      # Returns a zigzag-decoded signed 64-bit integer (sint64).
      #: () -> Integer
      def read_sint64
        v = read_varint
        (v >> 1) ^ -(v & 1)
      end

      # Returns an unsigned 32-bit little-endian integer.
      #: () -> Integer
      def read_fixed32
        read_fixed(4, "V")
      end

      # Returns an unsigned 64-bit little-endian integer.
      #: () -> Integer
      def read_fixed64
        read_fixed(8, "Q<")
      end

      #: () -> Integer
      def read_sfixed32
        read_fixed(4, "l<")
      end

      #: () -> Integer
      def read_sfixed64
        read_fixed(8, "q<")
      end

      #: () -> Float
      def read_float
        read_fixed(4, "e")
      end

      #: () -> Float
      def read_double
        read_fixed(8, "E")
      end

      # Reads a varint length and that many bytes
      #
      # Returns a new binary String.
      #: () -> String
      def read_bytes
        len = read_varint
        read_raw(len)
      end

      # Returns the next `length` bytes as a new binary String.
      #: (untyped length) -> String
      def read_raw(length)
        pos = @pos
        raise DecodeError.new("length #{length} runs past the end of the input", offset: pos) if pos + length > @limit
        @pos = pos + length
        s = @buffer.byteslice(pos, length)
        s.force_encoding(BINARY)
      end

      # Skips the value of a field whose tag was just read
      #
      # - `number`: the field number, needed to match the end of a group
      # - `depth`: groups left before DecodeError for nesting too deep
      #: (Integer number, Integer wire_type, ?Integer depth) -> untyped
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

      # Raises DecodeError unless `length` bytes remain before the limit.
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
          tag = read_tag_varint
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

      def self.check_tag(tag, at) # :nodoc:
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
