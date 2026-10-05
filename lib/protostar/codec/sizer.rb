# frozen_string_literal: true

module Protostar
  module Codec
    # The first encoding pass: the encoded size of a message and of every
    # message and packed run inside it, memoised in `sizes` (an identity Hash
    # that lives for one encode) so the writer knows each length prefix
    # before writing the bytes it covers.
    # @api private
    module Sizer
      F = Message::FieldInfo

      module_function

      # @param msg [Message]
      # @param sizes [Hash] compare_by_identity; filled with message and packed-run sizes
      # @return [Integer]
      def message(msg, sizes)
        known = sizes[msg]
        return known if known
        total = 0
        values = msg.__values
        msg.class.__encode_order.each do |info|
          v = values[info.index]
          next if v.nil?
          if info.map
            next if v.empty?
            tag = info.tag.bytesize
            v.each do |key, val|
              entry = entry(info, key, val, sizes)
              total += tag + Wire.varint_size(entry) + entry
            end
          elsif info.repeated
            next if v.empty?
            check(info, v)
            if info.packed
              run = packed(info, v)
              sizes[v] = run
              total += info.packed_tag.bytesize + Wire.varint_size(run) + run
            else
              tag = info.tag.bytesize
              tag *= 2 if info.kind == F::GROUP
              total += tag * v.size
              v.each { |e| total += value(info, e, sizes) }
            end
          elsif info.presence || !info.zero?(v)
            total += info.tag.bytesize
            total += info.end_tag.bytesize if info.kind == F::GROUP
            total += value(info, v, sizes)
          end
        end
        msg.unknown_fields.each do |u|
          total += Wire.varint_size((u.number << 3) | u.wire_type) + u.bytes.bytesize
        end
        sizes[msg] = total
      end

      # Size of one value, without its tag; a group's end tag is not included either
      def value(info, v, sizes)
        case info.kind
        when F::INT32, F::INT64, F::UINT32, F::UINT64 then Wire.varint_size(v)
        when F::ENUM then Wire.varint_size(Encoder.enum_number(info, v))
        when F::SINT32, F::SINT64 then Wire.varint_size((v << 1) ^ (v >> 63))
        when F::BOOL then 1
        when F::STRING, F::BYTES
          n = v.bytesize
          Wire.varint_size(n) + n
        when F::MESSAGE
          n = message(v, sizes)
          Wire.varint_size(n) + n
        when F::GROUP then message(v, sizes)
        when F::DOUBLE, F::FIXED64, F::SFIXED64 then 8
        else 4
        end
      end

      # Payload size of a packed run, without tag or length prefix
      def packed(info, list)
        case info.kind
        when F::DOUBLE, F::FIXED64, F::SFIXED64 then 8 * list.size
        when F::FLOAT, F::FIXED32, F::SFIXED32 then 4 * list.size
        when F::BOOL then list.size
        when F::SINT32, F::SINT64 then list.sum { |v| Wire.varint_size((v << 1) ^ (v >> 63)) }
        when F::ENUM then list.sum { |v| Wire.varint_size(Encoder.enum_number(info, v)) }
        else list.sum { |v| Wire.varint_size(v) }
        end
      end

      # Size of a map entry message: key field then value field, both always written
      def entry(info, key, val, sizes)
        k = info.key
        v = info.value
        check_one(k, key)
        check_one(v, val)
        k.tag.bytesize + value(k, key, sizes) + v.tag.bytesize + value(v, val, sizes)
      end

      def check(info, list)
        list.each { |e| check_one(info, e) }
      end

      def check_one(info, value)
        return if Message::Coercion.storable?(info, value)
        raise EncodeError, "#{info.descriptor.full_name} holds #{value.inspect[0, 64]}, which it cannot encode"
      end
    end
  end
end
