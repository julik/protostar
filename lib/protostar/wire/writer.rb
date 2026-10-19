# frozen_string_literal: true

module Protostar
  module Wire
    # Writes wire-format values into a binary String, or through a small
    # buffer into a sink: an IO, or anything that takes bytes.
    #
    # ```ruby
    # w = Protostar::Wire::Writer.new
    # w.write_tag(1, Protostar::Wire::VARINT).write_varint(150)
    # w.string # => "\x08\x96\x01"
    #
    # Protostar::Wire::Writer.new(io).write_bytes("hi").flush
    # ```
    class Writer
      # Bytes buffered before a sink is written to, by default
      FLUSH_AT = 64 * 1024

      # The bytes written so far (for a sink, those not yet flushed).
      attr_reader :string #: String
      # The sink, or nil for a String target.
      attr_reader :io #: untyped
      # Bytes buffered before the sink is written to.
      attr_reader :flush_at #: Integer

      # - `target`: a String to append to
      #   (it is switched to binary encoding), a sink, or nil for a new String.
      #   A sink is anything answering `write` (an IO, a socket, a Rack or
      #   ActionController::Live stream), `<<` (an Array, an Enumerator::Yielder)
      #   or `call` (a Proc). An IO or StringIO is given the buffer itself and
      #   anything else a copy, since a sink may keep what it is given.
      # - `flush_at`: bytes to collect before writing to the sink;
      #   0 writes on every #flush_if_full
      #: (?untyped target, ?flush_at: Integer) -> void
      def initialize(target = nil, flush_at: FLUSH_AT)
        @flush_at = flush_at
        if target.nil?
          @string = String.new(encoding: BINARY)
          @io = nil
        elsif target.is_a?(String)
          @string = target.force_encoding(BINARY)
          @io = nil
        else
          @string = String.new(capacity: (flush_at > 0) ? flush_at : 256, encoding: BINARY)
          @io = target
          @push = Writer.push_method(target)
          @copy = !(target.is_a?(IO) || (defined?(::StringIO) && target.is_a?(::StringIO)))
        end
      end

      # Returns how bytes are handed to `sink`: :write, :<< or :call.
      # Raises ArgumentError when it takes none of them.
      #: (untyped sink) -> Symbol
      def self.push_method(sink)
        # Proc#<< composes, so a callable is called before anything else is tried
        if sink.is_a?(Proc) || sink.is_a?(Method) then :call
        elsif sink.respond_to?(:write) then :write
        elsif sink.respond_to?(:<<) then :<<
        elsif sink.respond_to?(:call) then :call
        else
          raise ArgumentError, "#{sink.class} is not a sink: it answers none of write, << and call"
        end
      end

      # - `value`: negative values are written as ten-byte two's complement
      #: (Integer value) -> self
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

      #: (untyped number, untyped wire_type) -> self
      def write_tag(number, wire_type)
        write_varint((number << 3) | wire_type)
      end

      # - `value`: a signed integer, written zigzag-encoded (sint32, sint64)
      #: (Integer value) -> self
      def write_zigzag(value)
        write_varint((value << 1) ^ (value >> 63))
      end

      #: (untyped value) -> self
      def write_fixed32(value)
        [value].pack("V", buffer: @string)
        self
      end

      #: (untyped value) -> self
      def write_fixed64(value)
        [value].pack("Q<", buffer: @string)
        self
      end

      #: (untyped value) -> self
      def write_sfixed32(value)
        [value].pack("l<", buffer: @string)
        self
      end

      #: (untyped value) -> self
      def write_sfixed64(value)
        [value].pack("q<", buffer: @string)
        self
      end

      #: (untyped value) -> self
      def write_float(value)
        if value.is_a?(Float) && value.nan?
          @string << Wire.float_nan(value)
        else
          [value].pack("e", buffer: @string)
        end
        self
      end

      #: (untyped value) -> self
      def write_double(value)
        [value].pack("E", buffer: @string)
        self
      end

      # Writes a varint length followed by the bytes of `value`, whatever its encoding
      #: (untyped value) -> self
      def write_bytes(value)
        write_varint(value.bytesize)
        write_raw(value)
      end

      if String.method_defined?(:append_as_bytes)
        # Appends the bytes of `value` as they are, whatever its encoding
        #: (String value) -> self
        def write_raw(value)
          @string.append_as_bytes(value)
          flush_if_full
        end
      else
        # @rbs skip
        def write_raw(value) # :nodoc:
          # `<<` would raise or re-tag the buffer for a non-ASCII UTF-8 value
          [value].pack("a*", buffer: @string)
          flush_if_full
        end
      end

      # Writes the buffer to the sink once it holds #flush_at bytes
      #: () -> self
      def flush_if_full
        flush if @io && @string.bytesize >= @flush_at
        self
      end

      # Writes whatever is buffered to the sink. A no-op for a String target.
      #: () -> self
      def flush
        if @io && !@string.empty?
          deliver(@copy ? @string.dup : @string)
          @string.clear
        end
        self
      end

      # Writes the buffer and then `bytes` to the sink, without copying
      # `bytes` into the buffer first. For a String target, appends them.
      #: (untyped bytes) -> self
      def write_through(bytes)
        return write_raw(bytes) unless @io
        if @copy
          flush
          deliver(bytes.b)
        else
          # IO#write and StringIO#write take several Strings in one call
          deliver_all(@string, bytes)
          @string.clear
        end
        self
      end

      private

      def deliver_all(*chunks)
        @io.write(*chunks)
      end

      def deliver(bytes)
        case @push
        when :write then @io.write(bytes)
        when :<< then @io << bytes
        else @io.call(bytes)
        end
      end
    end
  end
end
