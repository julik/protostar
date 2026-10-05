# frozen_string_literal: true

module Protostar
  module Schema
    # Parses `FieldDescriptorProto.default_value` text into Ruby values
    # @api private
    module DefaultValue
      INTEGER_TYPES = %i[int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64].freeze
      SIMPLE_ESCAPES = {
        "a" => 7, "b" => 8, "f" => 12, "n" => 10, "r" => 13, "t" => 9, "v" => 11,
        "\\" => 92, "'" => 39, "\"" => 34, "?" => 63
      }.freeze

      # @param text [String] as protoc writes it
      # @param type [Symbol] the field's short type
      # @param enum [Enum, nil] the field's enum type
      # @return [Object]
      def self.parse(text, type, enum)
        case type
        when *INTEGER_TYPES then parse_integer(text)
        when :double then parse_float(text)
        when :float then to_float32(parse_float(text))
        when :bool
          case text
          when "true" then true
          when "false" then false
          else raise Error, "invalid bool default #{text.inspect}"
          end
        when :string then text
        when :bytes then unescape_bytes(text)
        when :enum
          raise Error, "enum default #{text.inspect} is not a value of #{enum.full_name}" unless enum.value(text)
          text.to_sym
        else
          raise Error, "a #{type} field cannot have a default value"
        end
      end

      def self.parse_integer(text)
        if text.match?(/\A-?0[xX]\h+\z/)
          Integer(text, 16)
        else
          Integer(text, 10)
        end
      rescue ArgumentError
        raise Error, "invalid integer default #{text.inspect}"
      end

      def self.parse_float(text)
        case text
        when "inf", "infinity" then Float::INFINITY
        when "-inf", "-infinity" then -Float::INFINITY
        when "nan", "-nan" then Float::NAN
        else Float(text)
        end
      rescue ArgumentError
        raise Error, "invalid floating point default #{text.inspect}"
      end

      # The value a float field actually holds: the nearest single-precision value
      def self.to_float32(value)
        return value if value.nan? || value.infinite?
        [value].pack("e").unpack1("e")
      end

      # Undoes protoc's CEscape: simple escapes, 1-3 digit octal, \x hex
      def self.unescape_bytes(text)
        text = text.b
        out = "".b
        i = 0
        n = text.bytesize
        while i < n
          byte = text.getbyte(i)
          if byte != 92 || i + 1 >= n # backslash
            out << byte
            i += 1
            next
          end
          c = text.byteslice(i + 1, 1)
          if (simple = SIMPLE_ESCAPES[c])
            out << simple
            i += 2
          elsif c.match?(/[0-7]/)
            digits = text.byteslice(i + 1, 3)[/\A[0-7]{1,3}/]
            out << (digits.to_i(8) & 0xFF)
            i += 1 + digits.bytesize
          elsif c == "x" || c == "X"
            digits = text.byteslice(i + 2, 2).to_s[/\A\h{1,2}/]
            raise Error, "invalid \\x escape in bytes default #{text.inspect}" unless digits
            out << digits.to_i(16)
            i += 2 + digits.bytesize
          else
            raise Error, "invalid escape \\#{c} in bytes default #{text.inspect}"
          end
        end
        out
      end
    end
  end
end
