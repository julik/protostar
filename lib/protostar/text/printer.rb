# frozen_string_literal: true

module Protostar
  module Text
    # Prints a message the way protoc's TextFormat::Printer does: fields in
    # number order, two-space indents, map entries sorted by key, strings
    # escaped with CEscape, floats in their shortest round-trip form, then
    # extensions and unknown fields.
    class Printer # :nodoc: all
      F = Message::FieldInfo

      # CEscape: named escapes, octal for every other byte outside printable ASCII
      ESCAPES = Array.new(256) do |b|
        case b
        when 0x0A then "\\n"
        when 0x0D then "\\r"
        when 0x09 then "\\t"
        when 0x22 then "\\\""
        when 0x27 then "\\'"
        when 0x5C then "\\\\"
        when 0x20..0x7E then b.chr
        else format("\\%03o", b)
        end.freeze
      end.freeze
      ESCAPED = /[^\x20-\x7e]|["'\\]/n
      UTF8_ESCAPED = /[\x00-\x1f\x7f"'\\]/
      ANY = "google.protobuf.Any"
      FLOAT_MIN_NORMAL = 1.1754943508222875e-38

      # Returns whether protoc prints the field by its message type's
      # name: a group whose field name is the type name in lower case.
      #: (untyped info) -> bool
      def self.group_like?(info)
        return false unless info.kind == F::GROUP
        type = info.descriptor.message_type
        type.name.downcase == info.name && type.file.equal?(info.descriptor.file) &&
          type.containing_message.equal?(info.descriptor.containing_message)
      end

      def initialize(single_line: false, expand_any: false, as_utf8: false, unknown_fields: true, registry: nil, pool: nil)
        @single_line = single_line
        @unknown_fields = unknown_fields
        @expand_any = expand_any
        @as_utf8 = as_utf8
        @registry = registry
        @extensions = Extensions.new(registry, pool)
      end

      #: (Message message) -> String
      def print(message)
        out = +""
        fields(message, out, 0)
        @single_line ? out.rstrip : out
      end

      private

      def fields(msg, out, depth)
        return if @expand_any && any(msg, out, depth)
        values = msg.__values
        items = []
        msg.class.__fields.each do |info|
          v = values[info.index]
          next if v.nil?
          if info.map || info.repeated
            next if v.empty?
          elsif !info.presence && info.zero?(v)
            next
          end
          items << [info, v]
        end
        unknown = msg.unknown_fields
        unless unknown.empty?
          extensions = @extensions.of(msg.class.descriptor)
          unless extensions.empty?
            unknown = extensions_as_items(unknown, extensions, items)
          end
        end
        items.sort_by! { |info, _| info.number }
        items.each { |info, v| field(info, v, out, depth) }
        unknown_fields(unknown.map { |u| [u.number, u.wire_type, u] }, out, depth) if @unknown_fields
      end

      # Moves the unknown fields that hold extensions into items; returns the rest
      def extensions_as_items(unknown, extensions, items)
        by_number = unknown.group_by(&:number)
        rest = unknown
        by_number.each do |number, list|
          field = extensions[number] or next
          info = @extensions.info(field) or next
          values = @extensions.read(info, list) or next
          next if values.empty?
          items << [info, info.repeated ? values : values.last]
          rest -= list
        end
        rest
      end

      def field(info, v, out, depth)
        extension = info.descriptor.extension?
        name = if extension then "[#{info.descriptor.full_name}]"
        elsif self.class.group_like?(info) then info.descriptor.message_type.name
        else info.name
        end
        if info.map
          v.keys.sort_by { |k| map_key_order(k) }.each do |k|
            open_block(name, out, depth)
            line("key: #{scalar(info.key, k)}", out, depth + 1)
            value = v[k]
            if info.value.message?
              open_block("value", out, depth + 1)
              fields(value, out, depth + 2)
              close_block(out, depth + 1)
            else
              line("value: #{scalar(info.value, value)}", out, depth + 1)
            end
            close_block(out, depth)
          end
        else
          (info.repeated ? v : [v]).each do |e|
            if info.message?
              open_block(name, out, depth)
              fields(e, out, depth + 1)
              close_block(out, depth)
            else
              line("#{name}: #{scalar(info, e)}", out, depth)
            end
          end
        end
      end

      def map_key_order(k)
        case k
        when false then 0
        when true then 1
        else k
        end
      end

      def line(text, out, depth)
        if @single_line
          out << text << " "
        else
          out << ("  " * depth) << text << "\n"
        end
      end

      def open_block(name, out, depth)
        line("#{name} {", out, depth)
      end

      def close_block(out, depth)
        line("}", out, depth)
      end

      def scalar(info, v)
        case info.kind
        when F::DOUBLE then double(v)
        when F::FLOAT then float(v)
        when F::BOOL then v ? "true" : "false"
        when F::STRING then quote(v, @as_utf8)
        when F::BYTES then quote(v, false)
        when F::ENUM then v.to_s
        else v.to_s
        end
      end

      def quote(s, utf8)
        if utf8 && s.valid_encoding? && s.encoding == Encoding::UTF_8
          "\"#{s.gsub(UTF8_ESCAPED) { |c| ESCAPES[c.ord] }}\""
        else
          "\"#{s.b.gsub(ESCAPED) { |c| ESCAPES[c.ord] }}\""
        end
      end

      def double(v)
        return nonfinite(v) unless v.finite?
        s = format("%.15g", v)
        back = Float(s)
        (back == v) ? s : format("%.17g", v)
      end

      # protoc reads the short form back with strtof, which it does not trust
      # for subnormal results, so those always get nine digits
      def float(v)
        return nonfinite(v) unless v.finite?
        s = format("%.6g", v)
        back = Message::Coercion.float32(Float(s))
        (back == v && (back == 0 || back.abs >= FLOAT_MIN_NORMAL)) ? s : format("%.9g", v)
      end

      def nonfinite(v)
        if v.nan? then "nan"
        elsif v > 0 then "inf"
        else "-inf"
        end
      end

      def any(msg, out, depth)
        return false unless msg.class.descriptor.full_name == ANY
        values = msg.__values
        by_name = msg.class.__by_name
        url = values[by_name.fetch("type_url").index]
        bytes = values[by_name.fetch("value").index]
        return false if url.nil? || url.empty? || !msg.unknown_fields.empty?
        slash = url.rindex("/")
        return false if slash.nil?
        klass = Types.find(url[(slash + 1)..], registry: @registry || Types.registry)
        return false unless klass.is_a?(Class)
        inner = begin
          klass.decode(bytes || "")
        rescue DecodeError
          return false
        end
        open_block("[#{url}]", out, depth)
        fields(inner, out, depth + 1)
        close_block(out, depth)
        true
      end

      # protoc's PrintUnknownFields: varints unsigned, fixed widths in hex,
      # length-delimited as a nested block when the bytes read as fields
      def unknown_fields(list, out, depth)
        list.each do |number, wire_type, value|
          case wire_type
          when Wire::VARINT
            line("#{number}: #{unknown_value(wire_type, value)}", out, depth)
          when Wire::FIXED32, Wire::FIXED64
            line("#{number}: #{unknown_value(wire_type, value)}", out, depth)
          when Wire::LENGTH_DELIMITED
            payload = value.is_a?(UnknownField) ? value.value : value
            nested = payload.empty? ? nil : UnknownSet.parse(payload)
            if nested
              open_block(number, out, depth)
              unknown_fields(nested, out, depth + 1)
              close_block(out, depth)
            else
              line("#{number}: #{quote(payload, false)}", out, depth)
            end
          when Wire::START_GROUP
            nested = value.is_a?(UnknownField) ? UnknownSet.parse(value.value) : value
            open_block(number, out, depth)
            unknown_fields(nested || [], out, depth + 1)
            close_block(out, depth)
          end
        end
      end

      def unknown_value(wire_type, value)
        value = value.value if value.is_a?(UnknownField)
        case wire_type
        when Wire::FIXED32 then format("0x%08x", value)
        when Wire::FIXED64 then format("0x%016x", value)
        else value.to_s
        end
      end

      # Reads bytes as a sequence of fields with no schema, the way protoc's
      # UnknownFieldSet does, to see whether a length-delimited field holds a message
      module UnknownSet # :nodoc: all
        MAX_DEPTH = 100

        module_function

        # Returns number, wire type and
        # value (Integer, payload String, or the fields of a group); nil when the
        # bytes are not a well-formed sequence of fields.
        #: (untyped bytes) -> Array[[Integer, Integer, untyped]]?
        def parse(bytes)
          r = Wire::Reader.new(bytes)
          list = read(r, nil, MAX_DEPTH)
          r.eof? ? list : nil
        rescue DecodeError
          nil
        end

        def read(r, group, depth)
          return nil if depth <= 0
          list = []
          until r.eof?
            tag = r.read_varint
            number = tag >> 3
            wire_type = tag & 7
            return nil if number == 0 || number > Wire::MAX_FIELD_NUMBER
            case wire_type
            when Wire::VARINT then list << [number, wire_type, r.read_varint]
            when Wire::FIXED64 then list << [number, wire_type, r.read_fixed64]
            when Wire::FIXED32 then list << [number, wire_type, r.read_fixed32]
            when Wire::LENGTH_DELIMITED then list << [number, wire_type, r.read_bytes]
            when Wire::START_GROUP
              nested = read(r, number, depth - 1) or return nil
              list << [number, wire_type, nested]
            when Wire::END_GROUP
              return (number == group) ? list : nil
            else return nil
            end
          end
          group ? nil : list
        end
      end
    end
  end
end
