# frozen_string_literal: true

module Protostar
  module Codec
    # Writes the two encoding passes of one message class as Ruby source and
    # evals them into the class: `__size(sizes)`, which returns the encoded
    # size and records it (and every packed run's) in `sizes`, and
    # `__write(w, buf, sizes)`, which appends the fields to the Writer's
    # buffer. Fields come in ascending number order, tags are literal bytes,
    # one-byte varints are appended inline, and enum names map to numbers
    # through a literal `case`. Maps, packed runs and unknown fields go to
    # {Sizer} and {Encoder}.
    #
    # The generic loop over field descriptors this replaces spent most of
    # its time on method calls into the field table.
    # @api private
    module EncodeGenerator
      F = Message::FieldInfo

      INT_BOUNDS = {
        F::INT32 => [-0x8000_0000, 0x7FFF_FFFF], F::SINT32 => [-0x8000_0000, 0x7FFF_FFFF],
        F::SFIXED32 => [-0x8000_0000, 0x7FFF_FFFF], F::UINT32 => [0, 0xFFFF_FFFF], F::FIXED32 => [0, 0xFFFF_FFFF],
        F::INT64 => [-0x8000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF],
        F::SINT64 => [-0x8000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF],
        F::SFIXED64 => [-0x8000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF],
        F::UINT64 => [0, 0xFFFF_FFFF_FFFF_FFFF], F::FIXED64 => [0, 0xFFFF_FFFF_FFFF_FFFF]
      }.freeze

      VARINT_KINDS = [F::INT32, F::INT64, F::UINT32, F::UINT64].freeze

      module_function

      # @param klass [Class]
      # @param fields [Array<Message::FieldInfo>]
      def install(klass, fields)
        ordered = fields.sort_by(&:number)
        klass.class_eval(source(ordered), "(protostar encoder #{klass.descriptor.full_name})", 1)
      end

      def source(fields)
        <<~RUBY
          # frozen_string_literal: true
          def __size(sizes)
            values = @values
            total = 0
            #{fields.map { |f| size_field(f) }.join}
            total += Protostar::Codec::Sizer.unknown(@unknown) if @unknown
            sizes[self] = total
          end

          def __write(w, buf, sizes)
            values = @values
            #{fields.map { |f| write_field(f) }.join}
            Protostar::Codec::Encoder.unknown(w, @unknown) if @unknown
            w.flush_if_full
          end
        RUBY
      end

      def info(f)
        "self.class.__fields[#{f.index}]"
      end

      # The condition under which a field is written, with its value in `v`
      def present(f)
        i = f.index
        if f.repeated || f.map
          "unless (v = values[#{i}]).nil? || v.empty?"
        elsif f.presence
          "unless (v = values[#{i}]).nil?"
        else
          "v = values[#{i}]\nif #{nonzero(f)}"
        end
      end

      # Negative zero is written, as protoc compares the bits
      def nonzero(f)
        case f.kind
        when F::DOUBLE, F::FLOAT then "v != 0 || (1.0 / v) < 0"
        when F::BOOL then "v"
        when F::STRING, F::BYTES then "!v.empty?"
        when F::ENUM
          zero = f.enum_names[0]
          zero ? "!v.equal?(#{zero.inspect}) && v != 0" : "v != 0"
        else "v != 0"
        end
      end

      def tag_bytes(f, wire_type = f.wire_type)
        Wire.tag_bytes(f.number, wire_type).bytes
      end

      def size_field(f)
        tag = tag_bytes(f).size
        body = if f.map
          "total += Protostar::Codec::Sizer.map(#{info(f)}, v, sizes)\n"
        elsif f.packed
          "run = sizes[v] = Protostar::Codec::Sizer.packed(#{info(f)}, v)\n" \
            "total += #{tag_bytes(f, Wire::LENGTH_DELIMITED).size} + #{varint_size("run")} + run\n"
        elsif f.repeated
          repeated_size(f, tag)
        else
          tags = (f.kind == F::GROUP) ? tag * 2 : tag
          "#{value_size(f, "v", "n")}total += #{tags} + n\n"
        end
        "# #{f.name}\n#{present(f)}\n#{body}end\n"
      end

      def repeated_size(f, tag)
        tag *= 2 if f.kind == F::GROUP
        src = "total += #{tag} * v.size\n"
        src << "k = #{info(f)}.message_class\n" if f.message?
        src << "v.each do |e|\n"
        src << "Protostar::Codec::Sizer.invalid(#{info(f)}, e) unless #{valid(f, "e")}\n" unless f.kind == F::ENUM
        src << value_size(f, "e", "n")
        src << "total += n\nend\n"
      end

      # Whether an element of a repeated field can be written; elements may
      # have been pushed into the plain Array past the writers' checks
      def valid(f, var)
        case f.kind
        when F::DOUBLE, F::FLOAT then "(#{var}.is_a?(Float) || #{var}.is_a?(Integer))"
        when F::BOOL then "(#{var} == true || #{var} == false)"
        when F::STRING, F::BYTES then "#{var}.is_a?(String)"
        when F::MESSAGE, F::GROUP then "#{var}.instance_of?(k)"
        else
          min, max = INT_BOUNDS.fetch(f.kind)
          "(#{var}.is_a?(Integer) && #{var} >= #{min} && #{var} <= #{max})"
        end
      end

      def varint_size(var)
        "((#{var} < 0x80 && #{var} >= 0) ? 1 : Protostar::Wire.varint_size(#{var}))"
      end

      # Statements leaving the size of value `var`, tag excluded, in `out`
      def value_size(f, var, out)
        case f.kind
        when *VARINT_KINDS then "#{out} = #{varint_size(var)}\n"
        when F::SINT32, F::SINT64 then "z = (#{var} << 1) ^ (#{var} >> 63)\n#{out} = #{varint_size("z")}\n"
        when F::BOOL then "#{out} = 1\n"
        when F::ENUM then "z = #{enum_number(f, var)}\n#{out} = #{varint_size("z")}\n"
        when F::STRING, F::BYTES then "#{out} = #{var}.bytesize\n#{out} += #{varint_size(out)}\n"
        when F::MESSAGE then "#{out} = #{var}.__size(sizes)\n#{out} += #{varint_size(out)}\n"
        when F::GROUP then "#{out} = #{var}.__size(sizes)\n"
        else "#{out} = #{F::FIXED.fetch(f.kind).first}\n"
        end
      end

      # An expression for the number of enum value `var`
      def enum_number(f, var)
        src = "case #{var}\n"
        f.enum_numbers.each { |name, number| src << "when #{name.inspect} then #{number}\n" }
        src << "when Integer then (#{var} >= -0x8000_0000 && #{var} <= 0x7FFF_FFFF) ? #{var} : " \
          "Protostar::Codec::Encoder.enum_number(#{info(f)}, #{var})\n"
        src << "else Protostar::Codec::Encoder.enum_number(#{info(f)}, #{var})\nend"
      end

      def write_field(f)
        body = if f.map
          "Protostar::Codec::Encoder.map(#{info(f)}, v, w, sizes)\n"
        elsif f.packed
          "#{append(tag_bytes(f, Wire::LENGTH_DELIMITED))}#{write_varint("sizes[v]")}" \
            "Protostar::Codec::Encoder.packed(#{info(f)}, v, w)\n"
        elsif f.repeated
          "v.each do |e|\n#{append(tag_bytes(f))}#{write_value(f, "e")}end\n"
        else
          "#{append(tag_bytes(f))}#{write_value(f, "v")}"
        end
        "# #{f.name}\n#{present(f)}\n#{body}end\n"
      end

      # Appending an Integer to a binary String appends that byte
      def append(bytes)
        "buf#{bytes.map { |b| " << #{b}" }.join}\n"
      end

      def write_varint(expr)
        "if (x = #{expr}) < 0x80 && x >= 0\nbuf << x\nelse\nw.write_varint(x)\nend\n"
      end

      def write_value(f, var)
        case f.kind
        when *VARINT_KINDS then write_varint(var)
        when F::SINT32, F::SINT64 then write_varint("(#{var} << 1) ^ (#{var} >> 63)")
        when F::BOOL then "buf << (#{var} ? 1 : 0)\n"
        when F::ENUM then write_varint(enum_number(f, var))
        when F::STRING, F::BYTES then "#{write_varint("#{var}.bytesize")}w.write_raw(#{var})\n"
        when F::MESSAGE then "#{write_varint("sizes[#{var}]")}#{var}.__write(w, buf, sizes)\n"
        when F::GROUP then "#{var}.__write(w, buf, sizes)\n#{append(tag_bytes(f, Wire::END_GROUP))}"
        else "[#{var}].pack(#{F::FIXED.fetch(f.kind).last.inspect}, buffer: buf)\n"
        end
      end
    end
  end
end
