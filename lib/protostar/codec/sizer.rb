# frozen_string_literal: true

module Protostar
  module Codec
    # The first encoding pass computes the encoded size of a message and of
    # every message and packed run inside it, recorded in `sizes` (an
    # identity Hash that lives for one encode) so the writer knows each
    # length prefix before it writes the bytes it covers. The per-class
    # `__size` methods ({EncodeGenerator}) do the work; this module has the
    # parts they share.
    # @api private
    module Sizer
      F = Message::FieldInfo

      module_function

      # @param msg [Message]
      # @param sizes [Hash] compare_by_identity
      # @return [Integer]
      def message(msg, sizes)
        msg.__size(sizes)
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
          n = v.__size(sizes)
          Wire.varint_size(n) + n
        when F::GROUP then v.__size(sizes)
        when F::DOUBLE, F::FIXED64, F::SFIXED64 then 8
        else 4
        end
      end

      # Payload size of a packed run, without tag or length prefix
      def packed(info, list)
        list.each { |e| check(info, e) }
        case info.kind
        when F::DOUBLE, F::FIXED64, F::SFIXED64 then 8 * list.size
        when F::FLOAT, F::FIXED32, F::SFIXED32 then 4 * list.size
        when F::BOOL then list.size
        when F::SINT32, F::SINT64 then list.sum { |v| Wire.varint_size((v << 1) ^ (v >> 63)) }
        when F::ENUM then list.sum { |v| Wire.varint_size(Encoder.enum_number(info, v)) }
        else list.sum { |v| Wire.varint_size(v) }
        end
      end

      # Size of every entry of a map field, tags and length prefixes included
      def map(info, hash, sizes)
        tag = info.tag.bytesize
        total = 0
        hash.each do |key, val|
          n = entry(info, key, val, sizes)
          total += tag + Wire.varint_size(n) + n
        end
        total
      end

      # Size of a map entry message: key field then value field, both always written
      def entry(info, key, val, sizes)
        k = info.key
        v = info.value
        check(k, key)
        check(v, val)
        k.tag.bytesize + value(k, key, sizes) + v.tag.bytesize + value(v, val, sizes)
      end

      # @param list [Array<UnknownField>]
      def unknown(list)
        list.sum { |u| Wire.varint_size((u.number << 3) | u.wire_type) + u.bytes.bytesize }
      end

      def check(info, value)
        invalid(info, value) unless Message::Coercion.storable?(info, value)
      end

      # @raise [EncodeError]
      def invalid(info, value)
        raise EncodeError, "#{info.descriptor.full_name} holds #{value.inspect[0, 64]}, which it cannot encode"
      end
    end
  end
end
