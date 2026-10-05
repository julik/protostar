# frozen_string_literal: true

module Protostar
  class View
    # What the generated index builders and the lazy containers share: the
    # rare paths of the scan, and turning indexed positions into values.
    # Every check mirrors the eager decoder's, with the same messages and offsets.
    # @api private
    module Scan
      F = Message::FieldInfo
      UTF_8 = Encoding::UTF_8
      BINARY = Encoding::BINARY

      module_function

      # A tag the class has no branch for: an end-group tag, a malformed tag,
      # an unknown field or a known one with the wrong wire type. The field is
      # skipped and its range kept for {View#unknown_fields}.
      def other(c, tag, at, ix, u, depth)
        number = tag >> 3
        wt = tag & 7
        raise DecodeError.new("unmatched end of group #{number}", offset: at) if wt == Wire::END_GROUP
        Wire::Reader.check_tag(tag, at)
        start = c.pos
        c.skip_field(number, wt, depth)
        (ix[u] ||= []) << number << wt << start << c.pos
      end

      # Skips a group's contents and its end tag
      # @return [Integer] the offset of the end tag, where the contents stop
      def group_end(c, number, depth)
        loop do
          raise DecodeError.new("missing end of group #{number}", offset: c.pos) if c.pos >= c.limit
          at = c.pos
          tag = c.read_varint
          n = tag >> 3
          wt = tag & 7
          if wt == Wire::END_GROUP
            return at if n == number
            raise DecodeError.new("unmatched end of group #{n}", offset: at)
          end
          Wire::Reader.check_tag(tag, at)
          c.skip_field(n, wt, depth)
        end
      end

      # Checks that a packed run is whole varints, as reading it would
      def check_varints(buf, pos, limit)
        while pos < limit
          start = pos
          shift = 0
          loop do
            raise DecodeError.new("truncated varint", offset: start) if pos >= limit
            byte = buf.getbyte(pos)
            pos += 1
            break if byte < 0x80
            shift += 7
            raise DecodeError.new("varint longer than 10 bytes", offset: start) if shift >= 70
          end
        end
      end

      # A packed run of a closed enum: numbers without a name become unknown fields
      def packed_closed_enum(c, pos, limit, ix, u, number, names)
        c.pos = pos
        old = c.push_limit(limit - pos)
        while c.pos < limit
          start = c.pos
          n = c.read_int32
          (ix[u] ||= []) << number << Wire::VARINT << start << c.pos unless names.key?(n)
        end
        c.pop_limit(old)
      end

      # @return [Boolean] whether a map entry's value is a closed enum's
      #   unknown number, which sends the whole entry to the unknown fields
      def map_unknown_enum?(buf, pos, length, info, depth)
        Map.entry(buf, pos, length, info, depth)[2]
      end

      def string(buf, offset, length, info)
        s = buf.byteslice(offset, length).force_encoding(UTF_8)
        if info.utf8_validation && !s.valid_encoding?
          raise DecodeError.new("invalid UTF-8 in #{info.descriptor.full_name}", offset: offset)
        end
        s.freeze
      end

      def bytes(buf, offset, length)
        buf.byteslice(offset, length).force_encoding(BINARY).freeze
      end

      # The value of a varint-encoded kind from the raw unsigned varint;
      # enums arrive already narrowed to int32
      def varint_value(kind, v, info)
        case kind
        when F::INT32
          v &= Wire::MASK32
          (v >= 0x8000_0000) ? v - 0x1_0000_0000 : v
        when F::INT64 then (v >= 0x8000_0000_0000_0000) ? v - 0x1_0000_0000_0000_0000 : v
        when F::UINT32 then v & Wire::MASK32
        when F::UINT64 then v
        when F::SINT32
          v &= Wire::MASK32
          (v >> 1) ^ -(v & 1)
        when F::SINT64 then (v >> 1) ^ -(v & 1)
        when F::BOOL then v != 0
        when F::ENUM then info.enum_names[v] || v
        end
      end

      # Every element of a repeated scalar field. `entries` holds pairs: a
      # value (varint kinds) or an offset (fixed kinds) and -1 for one
      # element, or an offset and a length for a packed run.
      # @return [Array] frozen
      def scalars(buf, info, entries)
        out = []
        kind = info.kind
        k = 0
        size = entries.size
        if (fixed = F::FIXED[kind])
          width, directive = fixed
          while k < size
            a = entries[k]
            b = entries[k + 1]
            if b < 0
              out << buf.unpack1(directive, offset: a)
            else
              stop = a + b
              while a < stop
                out << buf.unpack1(directive, offset: a)
                a += width
              end
            end
            k += 2
          end
        else
          c = nil
          enum = kind == F::ENUM
          names = info.enum_names
          while k < size
            a = entries[k]
            b = entries[k + 1]
            if b < 0
              out << varint_value(kind, a, info)
            else
              c ||= Wire::Reader.new(buf, 0, buf.bytesize)
              c.pos = a
              old = c.push_limit(b)
              stop = a + b
              while c.pos < stop
                if enum
                  n = c.read_int32
                  if (name = names[n])
                    out << name
                  elsif !info.closed_enum
                    out << n
                  end
                else
                  out << varint_value(kind, c.read_varint, info)
                end
              end
              c.pop_limit(old)
            end
            k += 2
          end
        end
        out.freeze
      end

      # A nested view over the segments of a message value
      def nested(info, buf, segments, depth)
        raise DecodeError.new("recursion limit exceeded", offset: segments[0]) if depth <= 0
        klass = info.message_class.__view_class
        case segments.size
        when 0 then klass.__new(buf, 0, 0, nil, depth - 1)
        when 2 then klass.__new(buf, segments[0], segments[1], nil, depth - 1)
        else klass.__new(buf, segments[0], segments[1], segments.freeze, depth - 1)
        end
      end
    end
  end
end
