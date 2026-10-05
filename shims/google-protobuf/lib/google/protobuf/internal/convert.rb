# frozen_string_literal: true

module Google
  module Protobuf
    module Internal
      # Checks and converts Ruby values on their way into a field, a
      # RepeatedField or a Map, with google-protobuf's rules and error
      # messages, into what protostar stores: Integers, Floats (single
      # precision for float), true/false, frozen Strings, enum Symbols (or
      # Integers for numbers without a name) and message instances.
      # @api private
      module Convert
        INTEGER_TYPES = {
          int32: [32, false], sint32: [32, false], sfixed32: [32, false],
          int64: [64, false], sint64: [64, false], sfixed64: [64, false],
          uint32: [32, true], fixed32: [32, true],
          uint64: [64, true], fixed64: [64, true]
        }.freeze

        FIXNUM = -(2**62)...(2**62)
        LONG = -(2**63)...(2**63)

        UTF_8 = Encoding::UTF_8
        BINARY = Encoding::BINARY
        TIMESTAMP = "google.protobuf.Timestamp"
        DURATION = "google.protobuf.Duration"

        module_function

        # @param value [Object]
        # @param type [Symbol] the field type as FieldDescriptor#type gives it
        # @param sub [Descriptor, EnumDescriptor, nil] for message and enum types
        # @param name [String] the field name, for error messages
        # @return [Object] what protostar stores
        def to_store(value, type, sub, name)
          case type
          when :double
            raise TypeError, "Expected number type for double field '#{name}' (given #{value.class})." unless number?(value)
            value.to_f
          when :float
            raise TypeError, "Expected number type for float field '#{name}' (given #{value.class})." unless number?(value)
            Protostar::Message::Coercion.float32(value.to_f)
          when :bool
            return value if value == true || value == false
            raise TypeError, "Invalid argument for boolean field '#{name}' (given #{value.class})."
          when :string then string(value, name)
          when :bytes then bytes(value, name)
          when :enum then enum(value, sub, name)
          when :message, :group then message(value, sub, name)
          else integer(value, type, name)
          end
        end

        def number?(value)
          value.is_a?(Integer) || value.is_a?(Float)
        end

        def string(value, name)
          if value.is_a?(Symbol)
            value = value.to_s
          elsif !value.is_a?(String)
            raise TypeError, "Invalid argument for string field '#{name}' (given #{value.class})."
          end
          if value.encoding != UTF_8
            value = value.encode(UTF_8)
          elsif !value.valid_encoding?
            raise Encoding::InvalidByteSequenceError, "String is invalid UTF-8"
          end
          value.frozen? ? value : value.dup.freeze
        end

        def bytes(value, name)
          raise TypeError, "Invalid argument for bytes field '#{name}' (given #{value.class})." unless value.instance_of?(String)
          value = value.encode(BINARY) if value.encoding != BINARY
          value.frozen? ? value : value.dup.freeze
        end

        def integer(value, type, name)
          given = value
          if value.is_a?(Float)
            if value.nan? || (value.finite? && value.floor != value)
              raise RangeError, "Non-integral floating point value assigned to integer field '#{name}' (given Float)."
            end
            raise RangeError, out_of_range(given, type) if value.infinite?
            value = value.to_i
          elsif !value.is_a?(Integer)
            raise TypeError, "Expected number type for integral field '#{name}' (given #{value.class})."
          end
          bits, unsigned = INTEGER_TYPES.fetch(type)
          if unsigned
            raise RangeError, "Assigning negative value to unsigned integer field '#{name}' (given #{given.class})." if value < 0
            return value if value.bit_length <= bits
          elsif value.bit_length < bits
            return value
          end
          raise RangeError, out_of_range(given, type)
        end

        # The message Ruby's NUM2INT and friends give, which the gem lets through
        def out_of_range(given, type)
          bits, unsigned = INTEGER_TYPES.fetch(type)
          if given.is_a?(Float)
            if bits == 64 || !LONG.cover?(given)
              target = if bits == 32 then "integer"
              else
                unsigned ? "unsigned long long" : "long long"
              end
              text = given.infinite? ? ((given > 0) ? "Inf" : "-Inf") : format("%-.10g", given)
              return "float #{text} out of range of #{target}"
            end
            given = given.to_i
          end
          if bits == 32 && FIXNUM.cover?(given)
            "integer #{given} too #{(given < 0) ? "small" : "big"} to convert to '#{unsigned ? "unsigned int" : "int"}'"
          elsif bits == 32
            "bignum too big to convert into '#{unsigned ? "unsigned long" : "long"}'"
          else
            "bignum too big to convert into '#{unsigned ? "unsigned long long" : "long long"}'"
          end
        end

        def enum(value, sub, name)
          case value
          when Integer, Float
            number = integer(value, :int32, name)
            sub.__names[number] || number
          when String, Symbol
            number = sub.__numbers[value.to_sym]
            raise RangeError, "Unknown symbol value for enum field '#{name}'." unless number
            sub.__names.fetch(number)
          else
            raise TypeError, "Expected number or symbol type for enum field '#{name}'."
          end
        end

        def message(value, sub, name)
          klass = sub.msgclass
          return value if value.instance_of?(klass)
          raise TypeError, "nil message not allowed here." if value.nil?
          case sub.name
          when TIMESTAMP
            return klass.new(seconds: value.to_i, nanos: value.nsec) if value.is_a?(::Time)
          when DURATION
            if value.is_a?(Numeric)
              seconds = value.to_i
              return klass.new(seconds: seconds, nanos: ((value.to_f - seconds) * 1_000_000_000).round)
            end
          end
          raise TypeError, "Invalid type #{value.class} to assign to submessage field '#{name}'."
        end

        # A field's value from a Hash given to `new`: Hashes become messages, here and nested
        # @return [Object] what protostar stores
        def initial(value, type, sub, name)
          if (type == :message || type == :group) && value.is_a?(Hash)
            sub.msgclass.new(value)
          else
            to_store(value, type, sub, name)
          end
        end

        # A stored value as the gem hands it out: enum values keep their Symbol
        # or Integer, everything else is what is stored
        def zero(type, sub)
          case type
          when :double, :float then 0.0
          when :bool then false
          when :string then ""
          when :bytes then "".b.freeze
          when :enum then sub.__names[0] || 0
          when :message, :group then nil
          else 0
          end
        end
      end
    end
  end
end
