# frozen_string_literal: true

module Protostar
  module Codec
    # Writes a decoding loop for one message class as Ruby source and evals
    # it into the class as `__decode_fields(r, buf, pos, limit, depth,
    # end_group, frozen)`, which reads the fields between `pos` and `limit`
    # and returns the position after them. The loop dispatches on the whole
    # tag with one `case` (field number and wire type at once), reads varints
    # of one or two bytes and fixed-width values inline, and keeps the
    # position and limit in locals. A nested message or group is read by a
    # call to the child's own `__decode_fields` from the parent's loop, so
    # each such call site sees one class and YJIT keeps it monomorphic.
    # Anything without a branch (unknown fields, wire type mismatches,
    # end-group tags, malformed tags, maps) goes to Decoder through the
    # reader `r`, moved to the local position and limit first.
    module DecodeGenerator # :nodoc: all
      F = Message::FieldInfo

      module_function

      #: (Class klass, Array[Message::FieldInfo] fields) -> untyped
      def install(klass, fields)
        klass.class_eval(source(fields), "(protostar decoder #{klass.descriptor.full_name})", 1)
      end

      def source(fields)
        branches = fields.map { |info| branch(info) }.join
        packed = fields.select { |info| info.packable && VARINT_KINDS.include?(info.kind) }.map { |info| packed_method(info) }
        <<~RUBY
          # frozen_string_literal: true
          #{packed.join}
          def __decode_fields(r, buf, pos, limit, depth, end_group, frozen)
            #{"values = @values" unless fields.empty?}
            while pos < limit
              at = pos
              if (tag = buf.getbyte(pos)) < 0x80
                pos += 1
              elsif pos + 1 < limit && (b = buf.getbyte(pos + 1)) < 0x80
                tag = (tag & 0x7F) | (b << 7)
                pos += 2
              else
                tag = r.__seek(pos, limit).read_tag_varint
                pos = r.pos
              end
              #{branches.empty? ? "if false" : "case tag"}
              #{branches}
              else
                if Protostar::Codec::Decoder.field(self, r.__seek(pos, limit), tag, at, depth, end_group, frozen)
                  @unknown&.freeze
                  return r.pos
                end
                pos = r.pos
              end
            end
            raise Protostar::DecodeError.new("missing end of group \#{end_group}", offset: pos) if end_group != 0
            @unknown&.freeze
            pos
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
          message(info)
        elsif info.kind == F::ENUM
          enum(info)
        else
          "#{read(info)}#{store(info, "v")}"
        end
        if info.packable
          packed_tag = (info.number << 3) | Wire::LENGTH_DELIMITED
          out << "when #{packed_tag} # #{info.name}, packed\n"
          out << if VARINT_KINDS.include?(info.kind)
            "#{varint("n")}#{check_length}pos = __decode_packed#{i}(r, buf, pos, pos + n, (values[#{i}] ||= []))\n"
          else
            slow("Protostar::Codec::Decoder.packed(self, values, self.class.__fields[#{i}], r)")
          end
        end
        out
      end

      # A message or group, read by the child's loop called from here; the
      # checks and their offsets are those of {Decoder.nested}
      def message(info)
        i = info.index
        src = +"raise Protostar::DecodeError.new(\"recursion limit exceeded\", offset: at) if depth <= 0\n"
        if info.kind == F::GROUP
          stop = "limit"
          group = info.number
        else
          src << varint("n") << check_length
          stop = "pos + n"
          group = 0
        end
        src << if info.repeated
          "sub = self.class.__fields[#{i}].message_class.__empty\n(values[#{i}] ||= []) << sub\n"
        else
          siblings = info.siblings ? info.siblings.map { |s| "values[#{s}] = nil\n" }.join : ""
          <<~RUBY
            if (sub = values[#{i}]).nil?
              #{siblings}sub = values[#{i}] = self.class.__fields[#{i}].message_class.__empty
            elsif sub.frozen?
              sub = values[#{i}] = sub.dup
            end
          RUBY
        end
        src << "pos = sub.__decode_fields(r, buf, pos, #{stop}, depth - 1, #{group}, frozen)\n"
        src << "sub.freeze if frozen\n"
      end

      def check_length
        "raise Protostar::DecodeError.new(\"length \#{n} runs past the end of the input\", offset: pos) if pos + n > limit\n"
      end

      VARINT_KINDS = [F::INT32, F::INT64, F::UINT32, F::UINT64, F::SINT32, F::SINT64, F::BOOL].freeze

      # A method reading a packed run of varints into `list` in one loop,
      # rather than a Decoder call per element; it returns the position
      # after the run. Kept out of `__decode_fields`, which YJIT runs slower
      # with the loops inline.
      def packed_method(info)
        <<~RUBY
          def __decode_packed#{info.index}(r, buf, pos, stop, list)
            while pos < stop
            #{read(info, "stop")}list << v
            end
            pos
          end
        RUBY
      end

      # Hands the reader to a Decoder method and picks the position back up
      def slow(call)
        "r.__seek(pos, limit)\n#{call}\npos = r.pos\n"
      end

      # Source reading a varint into `var`, inline when it is one or two
      # bytes; `lim` is where its input ends (a packed run's end, say)
      def varint(var, lim = "limit")
        <<~RUBY
          if pos < #{lim} && (#{var} = buf.getbyte(pos)) < 0x80
            pos += 1
          elsif pos + 1 < #{lim} && (b = buf.getbyte(pos + 1)) < 0x80
            #{var} = (#{var} & 0x7F) | (b << 7)
            pos += 2
          else
            #{var} = r.__seek(pos, #{lim}).read_varint
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
      def read(info, lim = "limit")
        case info.kind
        when F::INT32 then "#{varint("v", lim)}v -= 0x1_0000_0000 if (v &= 0xFFFF_FFFF) >= 0x8000_0000\n"
        when F::INT64 then "#{varint("v", lim)}v -= 0x1_0000_0000_0000_0000 if v >= 0x8000_0000_0000_0000\n"
        when F::UINT32 then "#{varint("v", lim)}v &= 0xFFFF_FFFF\n"
        when F::UINT64 then varint("v", lim)
        when F::SINT32 then "#{varint("v", lim)}v &= 0xFFFF_FFFF\nv = (v >> 1) ^ -(v & 1)\n"
        when F::SINT64 then "#{varint("v", lim)}v = (v >> 1) ^ -(v & 1)\n"
        when F::BOOL then "#{varint("v", lim)}v = v != 0\n"
        when F::STRING, F::BYTES then bytes(info)
        else fixed(*F::FIXED.fetch(info.kind))
        end
      end

      def bytes(info)
        src = varint("n") << check_length
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
        src = info.closed_enum ? "start = pos\n#{varint("v")}" : varint("v")
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
