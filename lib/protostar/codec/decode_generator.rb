# frozen_string_literal: true

module Protostar
  module Codec
    # Writes a decoding loop for one message class as Ruby source and evals
    # it into the class as `__decode_fields`. The loop dispatches on the whole
    # tag with one `case` (field number and wire type at once), reads varints
    # of one byte and fixed-width values inline, and keeps the read position
    # in a local. Anything it has no branch for (unknown fields, wire type
    # mismatches, end-group tags, malformed tags) goes to {Decoder.field}.
    #
    # A generic loop over field descriptors spent most of its time in method
    # calls on the field table; this does the same work with a fraction of them.
    # @api private
    module DecodeGenerator
      F = Message::FieldInfo

      module_function

      # @param klass [Class]
      # @param fields [Array<Message::FieldInfo>]
      def install(klass, fields)
        klass.class_eval(source(fields), "(protostar decoder #{klass.descriptor.full_name})", 1)
      end

      def source(fields)
        branches = fields.map { |info| branch(info) }.join
        <<~RUBY
          # frozen_string_literal: true
          def __decode_fields(r, depth, end_group, frozen)
            values = @values
            buf = r.buffer
            limit = r.limit
            pos = r.pos
            while pos < limit
              at = pos
              if (tag = buf.getbyte(pos)) < 0x80
                pos += 1
              elsif pos + 1 < limit && (b = buf.getbyte(pos + 1)) < 0x80
                tag = (tag & 0x7F) | (b << 7)
                pos += 2
              else
                r.pos = pos
                tag = r.read_tag_varint
                pos = r.pos
              end
              #{branches.empty? ? "if false" : "case tag"}
              #{branches}
              else
                r.pos = pos
                if Protostar::Codec::Decoder.field(self, r, tag, at, depth, end_group, frozen)
                  @unknown&.freeze
                  return
                end
                limit = r.limit
                pos = r.pos
              end
            end
            r.pos = pos
            Protostar::Codec::Decoder.finish(self, r, end_group)
          end
        RUBY
      end

      def branch(info)
        i = info.index
        tag = (info.number << 3) | info.wire_type
        out = "when #{tag} # #{info.name}\n"
        out << if info.map
          slow("Protostar::Codec::Decoder.map_entry(self, values, self.class.__fields[#{i}], r, depth, frozen)")
        elsif info.message?
          if info.repeated
            slow("Protostar::Codec::Decoder.repeated_message(values, self.class.__fields[#{i}], r, depth, frozen, at)")
          else
            slow("Protostar::Codec::Decoder.singular_message(values, self.class.__fields[#{i}], r, depth, frozen, at)")
          end
        elsif info.kind == F::ENUM
          enum(info)
        else
          "#{read(info)}#{store(info, "v")}"
        end
        if info.packable
          packed_tag = (info.number << 3) | Wire::LENGTH_DELIMITED
          out << "when #{packed_tag} # #{info.name}, packed\n"
          out << if VARINT_KINDS.include?(info.kind)
            packed(info)
          else
            slow("Protostar::Codec::Decoder.packed(self, values, self.class.__fields[#{i}], r)")
          end
        end
        out
      end

      VARINT_KINDS = [F::INT32, F::INT64, F::UINT32, F::UINT64, F::SINT32, F::SINT64, F::BOOL].freeze

      # A packed run of varints read in the loop rather than an element per
      # call: the run's end stands in for `limit` while it is read
      def packed(info)
        <<~RUBY
          #{varint("n")}raise Protostar::DecodeError.new("length \#{n} runs past the end of the input", offset: pos) if pos + n > limit
          list = (values[#{info.index}] ||= [])
          outer = limit
          limit = pos + n
          r.pop_limit(limit)
          while pos < limit
          #{read(info)}list << v
          end
          limit = outer
          r.pop_limit(limit)
        RUBY
      end

      # Hands the reader to a Decoder method and picks the position back up
      def slow(call)
        "r.pos = pos\n#{call}\npos = r.pos\n"
      end

      def varint(var)
        <<~RUBY
          if pos < limit && (#{var} = buf.getbyte(pos)) < 0x80
            pos += 1
          elsif pos + 1 < limit && (b = buf.getbyte(pos + 1)) < 0x80
            #{var} = (#{var} & 0x7F) | (b << 7)
            pos += 2
          else
            r.pos = pos
            #{var} = r.read_varint
            pos = r.pos
          end
        RUBY
      end

      def fixed(size, directive)
        <<~RUBY
          raise Protostar::DecodeError.new("truncated #{size * 8}-bit value", offset: pos) if pos + #{size} > limit
          v = buf.unpack1(#{directive.inspect}, offset: pos)
          pos += #{size}
        RUBY
      end

      # Source that leaves the field's next value in `v`
      def read(info)
        case info.kind
        when F::INT32 then "#{varint("v")}v -= 0x1_0000_0000 if (v &= 0xFFFF_FFFF) >= 0x8000_0000\n"
        when F::INT64 then "#{varint("v")}v -= 0x1_0000_0000_0000_0000 if v >= 0x8000_0000_0000_0000\n"
        when F::UINT32 then "#{varint("v")}v &= 0xFFFF_FFFF\n"
        when F::UINT64 then varint("v")
        when F::SINT32 then "#{varint("v")}v &= 0xFFFF_FFFF\nv = (v >> 1) ^ -(v & 1)\n"
        when F::SINT64 then "#{varint("v")}v = (v >> 1) ^ -(v & 1)\n"
        when F::BOOL then "#{varint("v")}v = v != 0\n"
        when F::STRING, F::BYTES then bytes(info)
        else fixed(*F::FIXED.fetch(info.kind))
        end
      end

      def bytes(info)
        src = varint("n")
        src << "raise Protostar::DecodeError.new(\"length \#{n} runs past the end of the input\", offset: pos) if pos + n > limit\n"
        src << "v = buf.byteslice(pos, n)\npos += n\n"
        if info.kind == F::BYTES
          src << "v.force_encoding(Encoding::BINARY).freeze\n"
        else
          src << "v.force_encoding(Encoding::UTF_8)\n"
          if info.utf8_validation
            src << "raise Protostar::DecodeError.new(\"invalid UTF-8 in #{info.descriptor.full_name}\", offset: pos - n) " \
              "unless v.valid_encoding?\n"
          end
          src << "v.freeze\n"
        end
        src
      end

      def enum(info)
        src = "start = pos\n#{varint("v")}"
        src << "v -= 0x1_0000_0000 if (v &= 0xFFFF_FFFF) >= 0x8000_0000\n"
        src << "if (e = self.class.__fields[#{info.index}].enum_names[v])\n"
        src << store(info, "e")
        src << if info.closed_enum
          "else\nProtostar::Codec::Decoder.closed_enum_value(self, #{info.number}, buf, start, pos)\n"
        else
          "else\n#{store(info, "v")}"
        end
        src << "end\n"
      end

      def store(info, var)
        i = info.index
        return "(values[#{i}] ||= []) << #{var}\n" if info.repeated
        siblings = info.siblings ? info.siblings.map { |s| "values[#{s}] = nil\n" }.join : ""
        "#{siblings}values[#{i}] = #{var}\n"
      end
    end
  end
end
