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

      # Returns a binary String.
      #: (untyped msg) -> String
      def encode(msg)
        sizes = {}.compare_by_identity
        size = msg.__size(sizes)
        w = Wire::Writer.new(String.new(capacity: size, encoding: BINARY))
        msg.__write(w, w.string, sizes)
        w.string
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
        sizes = {}.compare_by_identity
        size = msg.__size(sizes)
        w = Wire::Writer.new(io || String.new(capacity: size + 10, encoding: BINARY))
        w.write_varint(size)
        msg.__write(w, w.string, sizes)
        return w.string unless io
        w.flush
        io
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
