# frozen_string_literal: true

module Protostar
  module Codec
    # The second encoding pass: writes fields in ascending number order, then
    # unknown fields verbatim, using the sizes {Sizer} computed.
    # @api private
    module Encoder
      F = Message::FieldInfo
      BINARY = Encoding::BINARY

      module_function

      # @return [String] binary
      def encode(msg)
        sizes = {}.compare_by_identity
        size = Sizer.message(msg, sizes)
        w = Wire::Writer.new(String.new(capacity: size, encoding: BINARY))
        message(msg, w, sizes)
        w.string
      end

      def encode_to(msg, io)
        sizes = {}.compare_by_identity
        Sizer.message(msg, sizes)
        w = Wire::Writer.new(io)
        message(msg, w, sizes)
        w.flush
      end

      # @return [String, IO]
      def encode_delimited(msg, io)
        sizes = {}.compare_by_identity
        size = Sizer.message(msg, sizes)
        w = Wire::Writer.new(io || String.new(capacity: size + 10, encoding: BINARY))
        w.write_varint(size)
        message(msg, w, sizes)
        return w.string unless io
        w.flush
        io
      end

      # @return [Integer] the number of an enum value as stored (Symbol or Integer)
      def enum_number(info, v)
        return v if v.is_a?(Integer)
        info.enum_numbers.fetch(v) do
          raise EncodeError, "#{info.descriptor.full_name} holds #{v.inspect}, which is not a value of its enum"
        end
      end

      def message(msg, w, sizes)
        values = msg.__values
        msg.class.__encode_order.each do |info|
          v = values[info.index]
          next if v.nil?
          if info.map
            next if v.empty?
            key_info = info.key
            value_info = info.value
            v.each do |key, val|
              w.write_raw(info.tag)
              w.write_varint(Sizer.entry(info, key, val, sizes))
              w.write_raw(key_info.tag)
              value(key_info, key, w, sizes)
              w.write_raw(value_info.tag)
              value(value_info, val, w, sizes)
            end
          elsif info.repeated
            next if v.empty?
            if info.packed
              w.write_raw(info.packed_tag)
              w.write_varint(sizes.fetch(v))
              packed(info, v, w)
            else
              tag = info.tag
              v.each do |e|
                w.write_raw(tag)
                value(info, e, w, sizes)
              end
            end
          elsif info.presence || !info.zero?(v)
            w.write_raw(info.tag)
            value(info, v, w, sizes)
          end
        end
        msg.unknown_fields.each do |u|
          w.write_varint((u.number << 3) | u.wire_type)
          w.write_raw(u.bytes)
        end
        w.flush_if_full
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
          message(v, w, sizes)
        when F::GROUP
          message(v, w, sizes)
          w.write_raw(info.end_tag)
        when F::DOUBLE then w.write_double(v)
        when F::FLOAT then w.write_float(v)
        when F::FIXED64 then w.write_fixed64(v)
        when F::FIXED32 then w.write_fixed32(v)
        when F::SFIXED64 then w.write_sfixed64(v)
        when F::SFIXED32 then w.write_sfixed32(v)
        end
      end

      def packed(info, list, w)
        kind = info.kind
        if (fixed = F::FIXED[kind])
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
    end
  end
end
