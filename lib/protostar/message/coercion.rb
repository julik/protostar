# frozen_string_literal: true

module Protostar
  class Message
    # Checks and converts values assigned to fields. Everything stored in a
    # message has been through here (or through the decoder, which produces
    # the same shapes): Integers in range, Floats, true/false, frozen UTF-8 or
    # binary Strings, enum Symbols (or Integers for numbers without a name),
    # messages of the field's class.
    module Coercion # :nodoc: all
      RANGES = {
        FieldInfo::INT32 => -0x8000_0000..0x7FFF_FFFF,
        FieldInfo::SINT32 => -0x8000_0000..0x7FFF_FFFF,
        FieldInfo::SFIXED32 => -0x8000_0000..0x7FFF_FFFF,
        FieldInfo::UINT32 => 0..0xFFFF_FFFF,
        FieldInfo::FIXED32 => 0..0xFFFF_FFFF,
        FieldInfo::INT64 => -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF,
        FieldInfo::SINT64 => -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF,
        FieldInfo::SFIXED64 => -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF,
        FieldInfo::UINT64 => 0..0xFFFF_FFFF_FFFF_FFFF,
        FieldInfo::FIXED64 => 0..0xFFFF_FFFF_FFFF_FFFF
      }.freeze

      ENUM_RANGE = RANGES.fetch(FieldInfo::INT32)
      FLOAT_MAX = 3.4028234663852886e+38
      # Halfway between FLT_MAX and 2**128: doubles below it round to FLT_MAX
      FLOAT_ROUNDS_TO_MAX = 3.4028235677973366e+38
      UTF_8 = Encoding::UTF_8
      BINARY = Encoding::BINARY

      module_function

      # Returns what gets stored for a non-nil value assigned to the field.
      # Raises Protostar::TypeError.
      #: (FieldInfo info, untyped value) -> untyped
      def field(info, value)
        if info.map
          raise_type(info, value, "a Hash") unless value.is_a?(Hash)
          key = info.key
          val = info.value
          out = {}
          value.each { |k, v| out[scalar(key, k)] = single(val, v) }
          out
        elsif info.repeated
          raise_type(info, value, "an Array") unless value.is_a?(Array)
          value.map { |v| single(info, v) }
        else
          single(info, value)
        end
      end

      # One value of a singular field, an element of a repeated field, or a map value
      def single(info, value)
        if info.message?
          klass = info.message_class
          return value if value.instance_of?(klass)
          return klass.new(value) if value.is_a?(Hash)
          begin
            coerced = klass.__coerce(value)
          rescue RangeError
            raise_type(info, value, "a finite value in #{klass.descriptor.full_name}'s range")
          end
          return coerced if coerced
          raise_type(info, value, "a #{klass.descriptor.full_name} or a Hash")
        end
        scalar(info, value)
      end

      def scalar(info, value)
        case (kind = info.kind)
        when FieldInfo::DOUBLE
          raise_type(info, value, "a Numeric") unless value.is_a?(Float) || value.is_a?(Integer)
          value.to_f
        when FieldInfo::FLOAT
          raise_type(info, value, "a Numeric") unless value.is_a?(Float) || value.is_a?(Integer)
          # stored at single precision so that reads match what decoding gives back
          float32(value.to_f)
        when FieldInfo::BOOL
          raise_type(info, value, "true or false") unless value == true || value == false
          value
        when FieldInfo::STRING
          string(info, value)
        when FieldInfo::BYTES
          raise_type(info, value, "a String") unless value.is_a?(String)
          (value.frozen? && value.encoding == BINARY) ? value : value.b.freeze
        when FieldInfo::ENUM
          enum(info, value)
        else
          range = RANGES.fetch(kind)
          unless value.is_a?(Integer) && range.cover?(value)
            raise_type(info, value, "an Integer in #{info.descriptor.type} range")
          end
          value
        end
      end

      # The nearest single-precision value, as C's double-to-float conversion
      # gives it. `pack("e")` alone turns everything above FLT_MAX into
      # Infinity, even values that round down to FLT_MAX, and every NaN into
      # the same one.
      def float32(f)
        a = f.abs
        if a > FLOAT_MAX && a < FLOAT_ROUNDS_TO_MAX
          (f > 0) ? FLOAT_MAX : -FLOAT_MAX
        elsif f.nan?
          Wire.float_nan(f).unpack1("e")
        else
          [f].pack("e").unpack1("e")
        end
      end

      def string(info, value)
        raise_type(info, value, "a String") unless value.is_a?(String)
        enc = value.encoding
        if enc == UTF_8
          raise_type(info, value, "valid UTF-8") unless value.valid_encoding?
          value.frozen? ? value : value.dup.freeze
        elsif enc == BINARY || enc == Encoding::US_ASCII
          s = value.dup.force_encoding(UTF_8)
          raise_type(info, value, "valid UTF-8") unless s.valid_encoding?
          s.freeze
        else
          begin
            value.encode(UTF_8).freeze
          rescue EncodingError
            raise_type(info, value, "a String convertible to UTF-8")
          end
        end
      end

      def enum(info, value)
        if value.is_a?(Symbol)
          number = info.enum_numbers[value]
          raise_type(info, value, "a value of #{info.enum_module.descriptor.full_name}") unless number
          info.enum_names.fetch(number)
        elsif value.is_a?(Integer)
          name = info.enum_names[value]
          return name if name
          if info.closed_enum || !ENUM_RANGE.cover?(value)
            raise_type(info, value, "a value of #{info.enum_module.descriptor.full_name}")
          end
          value
        else
          raise_type(info, value, "a Symbol or Integer")
        end
      end

      # Whether a value found in a repeated field or map is one the encoder can
      # write. Those containers are plain Arrays and Hashes that callers may
      # have filled directly, past the writers' checks.
      def storable?(info, value)
        case (kind = info.kind)
        when FieldInfo::DOUBLE, FieldInfo::FLOAT then value.is_a?(Float) || value.is_a?(Integer)
        when FieldInfo::BOOL then value == true || value == false
        when FieldInfo::STRING, FieldInfo::BYTES then value.is_a?(String)
        when FieldInfo::ENUM
          value.is_a?(Symbol) ? info.enum_numbers.key?(value) : (value.is_a?(Integer) && ENUM_RANGE.cover?(value))
        when FieldInfo::MESSAGE, FieldInfo::GROUP then value.instance_of?(info.message_class)
        else value.is_a?(Integer) && RANGES.fetch(kind).cover?(value)
        end
      end

      def raise_type(info, value, expected)
        shown = value.inspect
        shown = "#{shown[0, 60]}..." if shown.length > 64
        raise Protostar::TypeError, "#{info.descriptor.full_name} expects #{expected}, got #{shown}"
      end
    end
  end
end
