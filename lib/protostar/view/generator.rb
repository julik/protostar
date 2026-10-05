# frozen_string_literal: true

module Protostar
  class View
    # Makes the view class of a message class: Ruby source for its index
    # builder and its readers, `class_eval`ed into a subclass of {View}, the
    # way {Codec::DecodeGenerator} makes decoders.
    #
    # A view of a class with `n` fields keeps one Array, the index:
    #
    #   [0, n)    per field: an inline varint value, an offset, a flat Array
    #             of offsets and lengths (merged messages), or the entries of
    #             a repeated or map field; nil when the field is not set
    #   [n, 2n)   the length belonging to an offset in the first part
    #   [2n, 3n)  decoded values, kept after the first read
    #   3n        unknown fields as number, wire type, start, end
    #   3n + 1    the UnknownField list, once asked for
    # @api private
    module Generator
      F = Message::FieldInfo

      module_function

      # @param klass [Class] a message class
      # @param fields [Array<Message::FieldInfo>]
      # @param oneofs [Array<Array(Symbol, Array<Integer>)>]
      # @return [Class] the view class
      def install(klass, fields, oneofs)
        view = Class.new(View)
        view.__define(klass, fields)
        view.class_eval(source(fields, oneofs, reserved), "(protostar view #{klass.descriptor.full_name})", 1)
        klass.instance_variable_set(:@__view_class, view)
        view
      end

      # Names a view must not lose to a field: its own methods and those a
      # message keeps for itself, so that views and messages have the same readers
      def reserved
        (View.public_instance_methods + Message.public_instance_methods + %i[initialize]).to_h { |m| [m, true] }
      end

      def source(fields, oneofs, reserved)
        n = fields.size
        taken = reserved.dup
        fields.each { |info| taken[:"__f#{info.index}"] = true }
        src = +"# frozen_string_literal: true\n"
        src << initializer(n)
        src << scanner(fields, n)
        fields.each { |info| src << reader(info, n) }
        fields.each do |info|
          name = info.name
          i = info.index
          [
            [name.to_sym, "alias_method :#{name}, :__f#{i}\n"],
            [:"#{name}=", "def #{name}=(_value); __frozen!; end\n"]
          ].each do |method, code|
            next if taken[method]
            taken[method] = true
            src << code
          end
          next unless info.presence
          [
            [:"has_#{name}?", "def has_#{name}?; !@ix[#{i}].nil?; end\n"],
            [:"clear_#{name}", "def clear_#{name}; __frozen!; end\n"]
          ].each do |method, code|
            next if taken[method]
            taken[method] = true
            src << code
          end
        end
        oneofs.each do |oneof_name, slots|
          which = :"which_#{oneof_name}"
          next if taken[which]
          taken[which] = true
          src << "def which_#{oneof_name}\nix = @ix\n"
          slots.each { |slot| src << "return :#{fields[slot].name} unless ix[#{slot}].nil?\n" }
          src << "nil\nend\n"
        end
        src
      end

      def initializer(n)
        <<~RUBY
          def initialize(buf, off, len, segs, depth)
            @buf = buf
            @off = off
            @len = len
            @segs = segs
            @depth = depth
            ix = Array.new(#{3 * n + 2})
            __scan(buf, off, off + len, ix, depth)
            if segs
              k = 2
              while k < segs.size
                __scan(buf, segs[k], segs[k] + segs[k + 1], ix, depth)
                k += 2
              end
            end
            @ix = ix
            freeze
          end
        RUBY
      end

      def scanner(fields, n)
        branches = fields.map { |info| branch(info, n) }.join
        <<~RUBY
          def __scan(buf, pos, limit, ix, depth)
            c = nil
            while pos < limit
              at = pos
              if (tag = buf.getbyte(pos)) < 0x80
                pos += 1
              elsif pos + 1 < limit && (b = buf.getbyte(pos + 1)) < 0x80
                tag = (tag & 0x7F) | (b << 7)
                pos += 2
              else
                c ||= Protostar::Wire::Reader.new(buf, pos, limit)
                c.pos = pos
                tag = c.read_varint
                pos = c.pos
              end
              #{branches.empty? ? "if false" : "case tag"}
              #{branches}
              else
                c ||= Protostar::Wire::Reader.new(buf, pos, limit)
                c.pos = pos
                Protostar::View::Scan.other(c, tag, at, ix, #{3 * n}, depth)
                pos = c.pos
              end
            end
          end
        RUBY
      end

      def branch(info, n)
        tag = (info.number << 3) | info.wire_type
        out = "when #{tag} # #{info.name}\n"
        out << if info.map
          map_branch(info, n)
        elsif info.kind == F::GROUP
          group_branch(info, n)
        elsif info.message? || info.kind == F::STRING || info.kind == F::BYTES
          "#{length}#{store_segment(info, n, "pos")}pos += len\n"
        elsif (fixed = F::FIXED[info.kind])
          width = fixed[0]
          "raise Protostar::DecodeError.new(\"truncated #{width * 8}-bit value\", offset: pos) if pos + #{width} > limit\n" \
            "#{store(info, "pos")}pos += #{width}\n"
        elsif info.kind == F::ENUM
          enum_branch(info, n)
        else
          "#{varint("v")}#{store(info, "v")}"
        end
        out << packed_branch(info, n) if info.packable
        out
      end

      # Reads a length prefix into `len`, checked against the limit
      def length
        "#{varint("len")}raise Protostar::DecodeError.new(\"length \#{len} runs past the end of the input\", offset: pos) if pos + len > limit\n"
      end

      def varint(var)
        <<~RUBY
          if pos < limit && (#{var} = buf.getbyte(pos)) < 0x80
            pos += 1
          elsif pos + 1 < limit && (b = buf.getbyte(pos + 1)) < 0x80
            #{var} = (#{var} & 0x7F) | (b << 7)
            pos += 2
          else
            c ||= Protostar::Wire::Reader.new(buf, pos, limit)
            c.pos = pos
            #{var} = c.read_varint
            pos = c.pos
          end
        RUBY
      end

      # A singular scalar, or one unpacked element of a repeated one
      def store(info, var)
        i = info.index
        return "(ix[#{i}] ||= []) << #{var} << -1\n" if info.repeated
        "#{clear_siblings(info)}ix[#{i}] = #{var}\n"
      end

      def clear_siblings(info)
        info.siblings ? info.siblings.map { |s| "ix[#{s}] = nil\n" }.join : ""
      end

      # A length-delimited value or group contents at `start`, `len` bytes long
      def store_segment(info, n, start)
        i = info.index
        return "(ix[#{i}] ||= []) << #{start} << len\n" if info.repeated
        return "#{clear_siblings(info)}ix[#{i}] = #{start}\nix[#{n + i}] = len\n" unless info.message?
        # a message that occurs again merges: its view reads every piece
        <<~RUBY
          if (o = ix[#{i}]).nil?
            #{clear_siblings(info)}ix[#{i}] = #{start}
            ix[#{n + i}] = len
          elsif o.is_a?(Integer)
            ix[#{i}] = [o, ix[#{n + i}], #{start}, len]
          else
            o << #{start} << len
          end
        RUBY
      end

      def group_branch(info, n)
        <<~RUBY
          c ||= Protostar::Wire::Reader.new(buf, pos, limit)
          c.pos = pos
          len = Protostar::View::Scan.group_end(c, #{info.number}, depth) - pos
          #{store_segment(info, n, "pos")}pos = c.pos
        RUBY
      end

      def enum_branch(info, n)
        narrow = "v -= 0x1_0000_0000 if (v &= 0xFFFF_FFFF) >= 0x8000_0000\n"
        return "#{varint("v")}#{narrow}#{store(info, "v")}" unless info.closed_enum
        src = "start = pos\n#{varint("v")}#{narrow}"
        src << "if self.class.__fields[#{info.index}].enum_names.key?(v)\n#{store(info, "v")}"
        src << "else\n(ix[#{3 * n}] ||= []) << #{info.number} << 0 << start << pos\nend\n"
      end

      def packed_branch(info, n)
        i = info.index
        out = "when #{(info.number << 3) | Wire::LENGTH_DELIMITED} # #{info.name}, packed\n#{length}"
        if (fixed = F::FIXED[info.kind])
          out << "raise Protostar::DecodeError.new(\"packed #{info.descriptor.type} length \#{len} is not a multiple of #{fixed[0]}\", offset: pos) " \
            "unless (len % #{fixed[0]}).zero?\n"
        elsif info.closed_enum
          out << "c ||= Protostar::Wire::Reader.new(buf, pos, limit)\n"
          out << "Protostar::View::Scan.packed_closed_enum(c, pos, pos + len, ix, #{3 * n}, #{info.number}, self.class.__fields[#{i}].enum_names)\n"
        else
          out << "Protostar::View::Scan.check_varints(buf, pos, pos + len)\n"
        end
        out << "(ix[#{i}] ||= []) << pos << len if len > 0\npos += len\n"
      end

      def map_branch(info, n)
        i = info.index
        if info.value.closed_enum
          out = "lp = pos\n#{length}"
          out << "if Protostar::View::Scan.map_unknown_enum?(buf, pos, len, self.class.__fields[#{i}], depth)\n"
          out << "(ix[#{3 * n}] ||= []) << #{info.number} << 2 << lp << pos + len\nelse\n"
          out << "(ix[#{i}] ||= []) << pos << len\nend\n"
        else
          out = "#{length}(ix[#{i}] ||= []) << pos << len\n"
        end
        out << "pos += len\n"
      end

      def reader(info, n)
        i = info.index
        m = 2 * n + i
        field = "self.class.__fields[#{i}]"
        body = if info.map
          "@ix[#{m}] ||= ((e = @ix[#{i}]) ? Protostar::View::Map.new(@buf, #{field}, e, @depth) : Protostar::View::Map::EMPTY)"
        elsif info.repeated
          "@ix[#{m}] ||= ((e = @ix[#{i}]) ? Protostar::View::Repeated.new(@buf, #{field}, e, @depth) : Protostar::View::Repeated::EMPTY)"
        elsif info.message?
          "ix = @ix\n(v = ix[#{m}]) ? v : ((o = ix[#{i}]) ? (ix[#{m}] = __nested(#{i}, o, ix[#{n + i}])) : nil)"
        elsif info.kind == F::STRING
          memo(i, m, info, "Protostar::View::Scan.string(@buf, o, ix[#{n + i}], #{field})")
        elsif info.kind == F::BYTES
          memo(i, m, info, "Protostar::View::Scan.bytes(@buf, o, ix[#{n + i}])")
        elsif (fixed = F::FIXED[info.kind])
          memo(i, m, info, "@buf.unpack1(#{fixed[1].inspect}, offset: o)")
        else
          "v = @ix[#{i}]\nreturn #{default(info)} if v.nil?\n#{convert(info)}"
        end
        "def __f#{i}\n#{body}\nend\n"
      end

      def memo(i, m, info, decode)
        "ix = @ix\n(v = ix[#{m}]).nil? ? ((o = ix[#{i}]) ? (ix[#{m}] = #{decode}) : #{default(info)}) : v"
      end

      def default(info)
        Message::Accessors.default_literal(info)
      end

      # Source turning the raw varint in `v` into the field's value
      def convert(info)
        case info.kind
        when F::INT32 then "v -= 0x1_0000_0000 if (v &= 0xFFFF_FFFF) >= 0x8000_0000\nv"
        when F::INT64 then "v >= 0x8000_0000_0000_0000 ? v - 0x1_0000_0000_0000_0000 : v"
        when F::UINT32 then "v & 0xFFFF_FFFF"
        when F::UINT64 then "v"
        when F::SINT32 then "v &= 0xFFFF_FFFF\n(v >> 1) ^ -(v & 1)"
        when F::SINT64 then "(v >> 1) ^ -(v & 1)"
        when F::BOOL then "v != 0"
        when F::ENUM then "self.class.__fields[#{info.index}].enum_names[v] || v"
        end
      end
    end
  end
end
