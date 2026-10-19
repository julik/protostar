# frozen_string_literal: true

module Protostar
  module Codec
    # Decodes the binary wire format into message objects, eagerly.
    module Decoder # :nodoc: all
      RECURSION_LIMIT = 100

      F = Message::FieldInfo
      UTF_8 = Encoding::UTF_8
      BINARY = Encoding::BINARY
      # unpack directive of a packed run of fixed-width values
      PACKED = F::FIXED.transform_values { |(_, d)| "#{d}*".freeze }.freeze

      module_function

      #: (untyped klass, untyped bytes, ?recursion_limit: untyped, ?frozen: untyped) -> Message
      def decode(klass, bytes, recursion_limit: RECURSION_LIMIT, frozen: false)
        r = Wire::Reader.new(bytes)
        msg = klass.__empty
        msg.__decode_fields(r, recursion_limit, 0, frozen)
        msg.freeze if frozen
        msg
      end

      #: (untyped klass, untyped source, **untyped options) -> Message?
      def decode_delimited(klass, source, **options)
        if source.is_a?(String) || (defined?(IO::Buffer) && source.is_a?(IO::Buffer))
          r = Wire::Reader.new(source)
          length = r.read_varint
          r.skip(length)
          return decode(klass, r.buffer.byteslice(r.pos - length, length), **options)
        end
        length = read_io_varint(source)
        return nil if length.nil?
        data = length.zero? ? +"" : source.read(length)
        if data.nil? || data.bytesize < length
          raise DecodeError, "truncated delimited message: expected #{length} bytes, got #{data ? data.bytesize : 0}"
        end
        decode(klass, data, **options)
      end

      # A varint from an IO, byte by byte; nil at a clean end of input
      def read_io_varint(io)
        result = 0
        shift = 0
        loop do
          byte = io.getbyte
          if byte.nil?
            return nil if shift == 0
            raise DecodeError, "truncated length prefix"
          end
          result |= (byte & 0x7F) << shift
          return result & Wire::MASK64 if byte < 0x80
          shift += 7
          raise DecodeError, "length prefix longer than 10 bytes" if shift >= 70
        end
      end

      # Decodes one field whose tag was just read from offset `at`. The
      # decoders generated for each class (DecodeGenerator) handle a class's
      # own fields inline and come here for everything else.
      #
      # Returns true when the tag ends the group being read.
      #: (untyped msg, untyped r, untyped tag, untyped at, untyped depth, untyped end_group, untyped frozen) -> bool
      def field(msg, r, tag, at, depth, end_group, frozen)
        number = tag >> 3
        wt = tag & 7
        if wt == Wire::END_GROUP
          return true if number == end_group && end_group != 0
          raise DecodeError.new("unmatched end of group #{number}", offset: at)
        end
        Wire::Reader.check_tag(tag, at)
        info = msg.class.__by_number[number]
        values = msg.__values
        if info.nil?
          unknown(msg, r, number, wt, depth)
        elsif wt == info.wire_type
          if info.map
            map_entry(msg, values, info, r, depth, frozen)
          elsif info.message?
            if info.repeated
              repeated_message(values, info, r, depth, frozen, at)
            else
              singular_message(values, info, r, depth, frozen, at)
            end
          elsif info.kind == F::ENUM
            enum(msg, values, info, r)
          elsif info.repeated
            (values[info.index] ||= []) << scalar(r, info)
          else
            siblings = info.siblings
            siblings&.each { |s| values[s] = nil }
            values[info.index] = scalar(r, info)
          end
        elsif wt == Wire::LENGTH_DELIMITED && info.packable
          packed(msg, values, info, r)
        else
          # a wire type that does not match the field makes it unknown, as in protoc
          unknown(msg, r, number, wt, depth)
        end
        false
      end

      # Checks the end of a message's fields: a group must have seen its end tag
      def finish(msg, r, end_group)
        raise DecodeError.new("missing end of group #{end_group}", offset: r.pos) if end_group != 0
        msg.__seal_unknown
      end

      def repeated_message(values, info, r, depth, frozen, at)
        sub = info.message_class.__empty
        nested(sub, info, r, depth, frozen, at)
        (values[info.index] ||= []) << sub
      end

      def singular_message(values, info, r, depth, frozen, at)
        i = info.index
        sub = values[i]
        if sub.nil?
          siblings = info.siblings
          siblings&.each { |s| values[s] = nil }
          sub = values[i] = info.message_class.__empty
        elsif sub.frozen?
          sub = values[i] = sub.dup
        end
        nested(sub, info, r, depth, frozen, at)
      end

      # Reads a message or group value into `sub`
      def nested(sub, info, r, depth, frozen, at)
        raise DecodeError.new("recursion limit exceeded", offset: at) if depth <= 0
        if info.kind == F::GROUP
          sub.__decode_fields(r, depth - 1, info.number, frozen)
        else
          old = r.push_limit(r.read_varint)
          sub.__decode_fields(r, depth - 1, 0, frozen)
          r.pop_limit(old)
        end
        sub.freeze if frozen
      end

      def unknown(msg, r, number, wt, depth)
        start = r.pos
        r.skip_field(number, wt, depth)
        bytes = r.buffer.byteslice(start, r.pos - start).force_encoding(BINARY).freeze
        msg.__add_unknown(UnknownField.new(number, wt, bytes))
      end

      def enum(msg, values, info, r)
        start = r.pos
        n = r.read_int32
        v = info.enum_names[n]
        if v.nil?
          if info.closed_enum
            bytes = r.buffer.byteslice(start, r.pos - start).force_encoding(BINARY).freeze
            msg.__add_unknown(UnknownField.new(info.number, Wire::VARINT, bytes))
            return
          end
          v = n
        end
        if info.repeated
          (values[info.index] ||= []) << v
        else
          siblings = info.siblings
          siblings&.each { |s| values[s] = nil }
          values[info.index] = v
        end
      end

      # One value of a scalar field other than an enum
      def scalar(r, info)
        case info.kind
        when F::INT32 then r.read_int32
        when F::INT64 then r.read_int64
        when F::UINT32 then r.read_uint32
        when F::UINT64 then r.read_varint
        when F::SINT32 then r.read_sint32
        when F::SINT64 then r.read_sint64
        when F::BOOL then r.read_varint != 0
        when F::STRING then string(r, info)
        when F::BYTES then r.read_bytes.freeze
        when F::DOUBLE then r.read_double
        when F::FLOAT then r.read_float
        when F::FIXED32 then r.read_fixed32
        when F::FIXED64 then r.read_fixed64
        when F::SFIXED32 then r.read_sfixed32
        when F::SFIXED64 then r.read_sfixed64
        when F::ENUM then r.read_int32
        else raise DecodeError, "#{info.descriptor.full_name} is not a scalar field"
        end
      end

      def string(r, info)
        s = r.read_bytes.force_encoding(UTF_8)
        if info.utf8_validation && !s.valid_encoding?
          raise DecodeError.new("invalid UTF-8 in #{info.descriptor.full_name}", offset: r.pos - s.bytesize)
        end
        s.freeze
      end

      # Keeps a closed enum's number that has no name as an unknown varint field
      def closed_enum_value(msg, number, buf, start, pos)
        bytes = buf.byteslice(start, pos - start).force_encoding(BINARY).freeze
        msg.__add_unknown(UnknownField.new(number, Wire::VARINT, bytes))
      end

      def packed(msg, values, info, r)
        old = r.push_limit(r.read_varint)
        list = (values[info.index] ||= [])
        kind = info.kind
        if (fixed = F::FIXED[kind])
          width = fixed[0]
          length = r.limit - r.pos
          raise DecodeError.new("packed #{info.descriptor.type} length #{length} is not a multiple of #{width}", offset: r.pos) unless (length % width).zero?
          # one unpack for the whole run instead of a read per element
          list.concat(r.read_raw(length).unpack(PACKED.fetch(kind)))
        elsif kind == F::ENUM
          names = info.enum_names
          closed = info.closed_enum
          while r.pos < r.limit
            start = r.pos
            n = r.read_int32
            v = names[n]
            if v
              list << v
            elsif closed
              bytes = r.buffer.byteslice(start, r.pos - start).force_encoding(BINARY).freeze
              msg.__add_unknown(UnknownField.new(info.number, Wire::VARINT, bytes))
            else
              list << n
            end
          end
        else
          list << scalar(r, info) while r.pos < r.limit
        end
        r.pop_limit(old)
      end

      def map_entry(msg, values, info, r, depth, frozen)
        start = r.pos
        old = r.push_limit(r.read_varint)
        key_info = info.key
        value_info = info.value
        key = nil
        value = nil
        unknown_enum = false
        while r.pos < r.limit
          at = r.pos
          tag = r.read_tag_varint
          Wire::Reader.check_tag(tag, at)
          number = tag >> 3
          wt = tag & 7
          if number == 1 && wt == key_info.wire_type
            key = scalar(r, key_info)
          elsif number == 2 && wt == value_info.wire_type
            if value_info.message?
              if value.nil?
                value = value_info.message_class.__empty
              elsif value.frozen?
                value = value.dup
              end
              nested(value, value_info, r, depth, frozen, at)
            elsif value_info.kind == F::ENUM
              n = r.read_int32
              value = value_info.enum_names[n]
              if value.nil?
                unknown_enum = value_info.closed_enum
                value = n
              else
                unknown_enum = false
              end
            else
              value = scalar(r, value_info)
            end
          else
            raise DecodeError.new("unmatched end of group #{number}", offset: at) if wt == Wire::END_GROUP
            r.skip_field(number, wt, depth)
          end
        end
        r.pop_limit(old)
        if unknown_enum
          # protoc keeps the whole entry as an unknown field of the map
          bytes = r.buffer.byteslice(start, r.pos - start).force_encoding(BINARY).freeze
          msg.__add_unknown(UnknownField.new(info.number, Wire::LENGTH_DELIMITED, bytes))
          return
        end
        key = key_info.default if key.nil?
        if value.nil?
          value = value_info.message? ? value_info.message_class.__empty : value_info.default
        end
        value.freeze if frozen
        (values[info.index] ||= {})[key] = value
      end
    end
  end
end
