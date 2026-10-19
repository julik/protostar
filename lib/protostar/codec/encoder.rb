# frozen_string_literal: true

module Protostar
  module Codec
    # The second encoding pass writes fields in ascending number order, then
    # unknown fields verbatim, using the sizes the first pass recorded. The
    # per-class `__write` methods (EncodeGenerator) do the work; this
    # module has the entry points and the parts they share.
    module Encoder # :nodoc: all
      F = Message::FieldInfo
      BINARY = Encoding::BINARY

      module_function

      # Zero bytes to splice in for a length longer than its reserved byte
      PAD = (0..9).map { |n| ("\0" * n).b.freeze }.freeze

      # Returns a binary String.
      #: (untyped msg) -> String
      def encode(msg)
        buf = String.new(encoding: BINARY)
        msg.__encode(Wire::Writer.new(buf), buf)
      end

      def encode_to(msg, io)
        sizes = {}.compare_by_identity
        msg.__size(sizes)
        w = Wire::Writer.new(io)
        msg.__write(w, w.string, sizes)
        w.flush
      end

      #: (untyped msg, untyped io) -> (String | IO)
      def encode_delimited(msg, io)
        unless io
          buf = String.new(encoding: BINARY) << 0
          msg.__encode(Wire::Writer.new(buf), buf)
          n = buf.bytesize - 1
          (n < 0x80) ? buf.setbyte(0, n) : patch_length(buf, 0, n)
          return buf
        end
        sizes = {}.compare_by_identity
        size = msg.__size(sizes)
        w = Wire::Writer.new(io)
        w.write_varint(size)
        msg.__write(w, w.string, sizes)
        w.flush
        io
      end

      # Writes length `n` into the byte reserved for it at `at`, splicing in
      # as many more as the varint needs
      def patch_length(buf, at, n)
        buf.bytesplice(at + 1, 0, PAD[Wire.varint_size(n) - 1])
        while n >= 0x80
          buf.setbyte(at, (n & 0x7F) | 0x80)
          n >>= 7
          at += 1
        end
        buf.setbyte(at, n)
      end

      # Every entry of a map field, in insertion order, key then value, for
      # the one-pass encoder; checks what Sizer.entry checks
      def map_into(info, hash, w, buf)
        key_info = info.key
        value_info = info.value
        tag = info.tag
        hash.each do |key, val|
          Sizer.check(key_info, key)
          Sizer.check(value_info, val)
          w.write_raw(tag)
          at = buf.bytesize
          buf << 0
          w.write_raw(key_info.tag)
          value(key_info, key, w, nil)
          w.write_raw(value_info.tag)
          if value_info.kind == F::MESSAGE
            inner = buf.bytesize
            buf << 0
            val.__encode(w, buf)
            n = buf.bytesize - inner - 1
            (n < 0x80) ? buf.setbyte(inner, n) : patch_length(buf, inner, n)
          elsif value_info.kind == F::GROUP
            val.__encode(w, buf)
            w.write_raw(value_info.end_tag)
          else
            value(value_info, val, w, nil)
          end
          n = buf.bytesize - at - 1
          (n < 0x80) ? buf.setbyte(at, n) : patch_length(buf, at, n)
        end
      end

      # Returns the number of an enum value as stored (Symbol or Integer).
      # Raises EncodeError for a name the enum does not have or an Integer out of int32 range.
      #: (untyped info, untyped v) -> Integer
      def enum_number(info, v)
        if v.is_a?(Integer)
          return v if Message::Coercion::ENUM_RANGE.cover?(v)
        elsif (n = info.enum_numbers[v])
          return n
        end
        raise EncodeError, "#{info.descriptor.full_name} holds #{v.inspect[0, 64]}, which is not a value of its enum"
      end

      # One value, without its tag; a group's end tag is written here
      def value(info, v, w, sizes)
        case info.kind
        when F::INT32, F::INT64, F::UINT32, F::UINT64 then w.write_varint(v)
        when F::ENUM then w.write_varint(enum_number(info, v))
        when F::SINT32, F::SINT64 then w.write_varint((v << 1) ^ (v >> 63))
        when F::BOOL then w.write_varint(v ? 1 : 0)
        when F::STRING, F::BYTES then w.write_bytes(v)
        when F::MESSAGE
          w.write_varint(sizes.fetch(v))
          v.__write(w, w.string, sizes)
        when F::GROUP
          v.__write(w, w.string, sizes)
          w.write_raw(info.end_tag)
        when F::DOUBLE then w.write_double(v)
        when F::FLOAT then w.write_float(v)
        when F::FIXED64 then w.write_fixed64(v)
        when F::FIXED32 then w.write_fixed32(v)
        when F::SFIXED64 then w.write_sfixed64(v)
        when F::SFIXED32 then w.write_sfixed32(v)
        end
      end

      # The payload of a packed run; tag and length are already written
      def packed(info, list, w)
        kind = info.kind
        if kind == F::FLOAT
          w.write_raw(Wire.pack_floats(list))
        elsif (fixed = F::FIXED[kind])
          # one pack for the whole run
          w.write_raw(list.pack("#{fixed[1]}*"))
        elsif kind == F::ENUM
          list.each { |v| w.write_varint(enum_number(info, v)) }
        elsif kind == F::BOOL
          list.each { |v| w.write_varint(v ? 1 : 0) }
        elsif kind == F::SINT32 || kind == F::SINT64
          list.each { |v| w.write_varint((v << 1) ^ (v >> 63)) }
        else
          list.each { |v| w.write_varint(v) }
        end
      end

      # Every entry of a map field, in insertion order, key then value
      def map(info, hash, w, sizes)
        key_info = info.key
        value_info = info.value
        hash.each do |key, val|
          w.write_raw(info.tag)
          w.write_varint(Sizer.entry(info, key, val, sizes))
          w.write_raw(key_info.tag)
          value(key_info, key, w, sizes)
          w.write_raw(value_info.tag)
          value(value_info, val, w, sizes)
        end
      end

      #: (untyped w, Array[UnknownField] list) -> untyped
      def unknown(w, list)
        list.each do |u|
          w.write_varint((u.number << 3) | u.wire_type)
          w.write_raw(u.bytes)
        end
      end
    end
  end
end
