# frozen_string_literal: true

module Protostar
  module Text
    # Reads protoc's text format into a message, with protoc's grammar and
    # its checks: non-repeated fields and oneofs set at most once, enum
    # names and numbers known to closed enums, integers in range.
    # @api private
    class Parser
      F = Message::FieldInfo
      RANGES = Message::Coercion::RANGES
      CLOSE = {"{" => "}", "<" => ">"}.freeze
      TRUE_WORDS = %w[true True t].freeze
      FALSE_WORDS = %w[false False f].freeze
      SIMPLE_ESCAPES = {
        "a" => "\a", "b" => "\b", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t", "v" => "\v",
        "\\" => "\\", "'" => "'", "\"" => "\"", "?" => "?"
      }.freeze
      ESCAPE = /\\(?:([0-7]{1,3})|x(\h{1,2})|u(\h{4})|U(\h{8})|(.))/mn
      ANY = "google.protobuf.Any"
      UNSIGNED = [F::UINT32, F::UINT64, F::FIXED32, F::FIXED64].freeze

      def initialize(text, allow_unknown_fields: false, allow_partial: true, registry: Types.registry, pool: nil)
        @tokens = Tokenizer.new(text)
        @allow_unknown = allow_unknown_fields
        @allow_partial = allow_partial
        @registry = registry
        @extensions = Extensions.new(registry, pool)
      end

      # @param klass [Class]
      # @return [Message]
      def parse(klass)
        msg = klass.new
        message_body(msg, nil)
        if !@allow_partial && !msg.initialized?
          @tokens.fail!("message of type #{klass.descriptor.full_name} is missing required fields", @tokens.peek.pos)
        end
        msg
      end

      private

      def fail!(message, token = @tokens.peek)
        @tokens.fail!(message, token.pos)
      end

      def accept(text)
        t = @tokens.peek
        return false unless t.type == :symbol && t.text == text
        @tokens.next
        true
      end

      def expect(text)
        accept(text) || fail!("expected \"#{text}\", got #{shown(@tokens.peek)}")
      end

      def shown(token)
        (token.type == :eof) ? "end of input" : "\"#{token.text}\""
      end

      # Fields up to the closing delimiter, or the end of input when there is none
      def message_body(msg, close)
        seen = {}
        extensions = nil
        loop do
          t = @tokens.peek
          if close.nil? ? t.type == :eof : (t.type == :symbol && t.text == close)
            @tokens.next if close
            break
          end
          fail!("expected \"#{close}\", got end of input") if t.type == :eof
          if accept("[")
            name, name_token = bracketed_name
            if name.include?("/")
              any_expansion(msg, name, name_token)
            else
              extensions ||= {}
              extension(msg, name, name_token, extensions)
            end
          else
            field(msg, seen)
          end
          accept(";") || accept(",")
        end
        add_extensions(msg, extensions) if extensions
      end

      def bracketed_name
        start = @tokens.peek
        name = +""
        until accept("]")
          t = @tokens.next
          fail!("expected \"]\", got end of input", t) if t.type == :eof
          name_part = t.type == :identifier || (t.type == :symbol && "./".include?(t.text))
          fail!("unexpected #{shown(t)} in a bracketed name", t) unless name_part
          name << t.text
        end
        [name, start]
      end

      def field(msg, seen)
        t = @tokens.next
        fail!("expected a field name, got #{shown(t)}", t) unless t.type == :identifier
        klass = msg.class
        info = lookup(klass, t.text)
        unless info
          fail!("message type \"#{klass.descriptor.full_name}\" has no field named \"#{t.text}\"", t) unless @allow_unknown
          return skip_value
        end
        if !info.repeated && !info.map
          if seen[info]
            fail!("non-repeated field \"#{info.name}\" is specified multiple times", t)
          end
          if (oneof = info.descriptor.real_oneof) && (other = seen[oneof])
            fail!("field \"#{info.name}\" is specified along with field \"#{other.name}\", another member of oneof \"#{oneof.name}\"", t)
          end
          seen[info] = true
          seen[oneof] = info if oneof
        end
        values = field_values(info, klass)
        assign(msg, info, values, t)
      end

      # A field by name; groups also by their type name, as protoc prints them
      def lookup(klass, name)
        info = klass.__by_name[name]
        return info if info
        info = klass.__by_name[name.downcase]
        info if info && Printer.group_like?(info) && info.descriptor.message_type.name == name
      end

      # The value or values after a field name: `: scalar`, `: [list]`, `{ message }`
      def field_values(info, klass)
        if info.message?
          colon = accept(":")
          return list { message_value(info) } if (info.repeated || info.map) && accept("[")
          fail!("expected \"{\" or \"<\" after \"#{info.name}#{":" if colon}\", got #{shown(@tokens.peek)}") unless open?
          [message_value(info)]
        else
          expect(":")
          if info.repeated && accept("[")
            list { scalar(info) }
          else
            [scalar(info)]
          end
        end
      end

      def open?
        t = @tokens.peek
        t.type == :symbol && CLOSE.key?(t.text)
      end

      def list
        out = []
        return out if accept("]")
        loop do
          out << yield
          break if accept("]")
          expect(",")
        end
        out
      end

      def assign(msg, info, values, token)
        if info.map
          hash = msg.__values[info.index] || {}
          values.each { |entry| hash[entry.first] = entry.last }
          store(msg, info, hash, token)
        elsif info.repeated
          store(msg, info, (msg.__values[info.index] || []) + values, token)
        else
          store(msg, info, values.first, token)
        end
      end

      def store(msg, info, value, token)
        msg.__set(info.index, value)
      rescue Protostar::TypeError => e
        fail!(e.message, token)
      end

      def message_value(info)
        t = @tokens.next
        close = CLOSE[t.text] if t.type == :symbol
        fail!("expected \"{\" or \"<\", got #{shown(t)}", t) unless close
        if info.map
          map_entry(info, close)
        else
          msg = info.message_class.new
          message_body(msg, close)
          msg
        end
      end

      # A map entry as a message with `key` and `value`; either may be left out
      def map_entry(info, close)
        key = nil
        value = nil
        until accept(close)
          t = @tokens.next
          fail!("expected \"#{close}\", got end of input", t) if t.type == :eof
          case t.text
          when "key"
            expect(":")
            key = scalar(info.key)
          when "value"
            if info.value.message?
              accept(":")
              value = message_value(info.value)
            else
              expect(":")
              value = scalar(info.value)
            end
          else
            fail!("map entry has no field named \"#{t.text}\"", t)
          end
          accept(";") || accept(",")
        end
        key = info.key.default if key.nil?
        value = (info.value.message? ? info.value.message_class.new : info.value.default) if value.nil?
        [key, value]
      end

      def scalar(info)
        case info.kind
        when F::DOUBLE, F::FLOAT then float(info)
        when F::BOOL then bool
        when F::STRING, F::BYTES then string(info)
        when F::ENUM then enum(info)
        else integer(info)
        end
      end

      def integer(info)
        negative = !UNSIGNED.include?(info.kind) && accept("-")
        t = @tokens.next
        fail!("expected an integer, got #{shown(t)}", t) unless t.type == :integer
        n = integer_value(t)
        n = -n if negative
        range = RANGES.fetch(info.kind)
        fail!("integer out of range (#{"-" if negative}#{t.text})", t) unless range.cover?(n)
        n
      end

      def integer_value(t)
        text = t.text
        if text.start_with?("0x", "0X")
          text[2..].to_i(16)
        elsif text.length > 1 && text.start_with?("0")
          fail!("numbers starting with a leading zero must be in octal", t) unless /\A[0-7]+\z/.match?(text)
          text.to_i(8)
        else
          text.to_i
        end
      end

      def float(info)
        negative = accept("-")
        t = @tokens.next
        f = case t.type
        when :float then Float(t.text.delete_suffix("f").delete_suffix("F"))
        when :integer
          fail!("expected a decimal number, got \"#{t.text}\"", t) if t.text.length > 1 && t.text.start_with?("0")
          Float(t.text)
        when :identifier
          case t.text.downcase
          when "inf", "infinity" then Float::INFINITY
          when "nan" then Float::NAN
          else fail!("expected a number, got \"#{t.text}\"", t)
          end
        else fail!("expected a number, got #{shown(t)}", t)
        end
        f = -f if negative
        (info.kind == F::FLOAT) ? Message::Coercion.float32(f) : f
      end

      def bool
        t = @tokens.next
        if t.type == :identifier
          return true if TRUE_WORDS.include?(t.text)
          return false if FALSE_WORDS.include?(t.text)
        elsif t.type == :integer
          return true if t.text == "1"
          return false if t.text == "0"
        end
        fail!("invalid value for a boolean field: #{shown(t)}", t)
      end

      # One or more adjacent string literals, concatenated
      def string(info)
        t = @tokens.next
        fail!("expected a string, got #{shown(t)}", t) unless t.type == :string
        out = unescape(t)
        out << unescape(@tokens.next) while @tokens.peek.type == :string
        if info.kind == F::STRING
          out.force_encoding(Encoding::UTF_8)
          fail!("string is not valid UTF-8", t) unless out.valid_encoding?
        end
        out
      end

      def unescape(t)
        body = t.text[1..-2].b
        out = String.new(encoding: Encoding::BINARY)
        out << body.gsub(ESCAPE) do
          m = $~
          if m[1] then (m[1].to_i(8) & 0xFF).chr
          elsif m[2] then m[2].to_i(16).chr
          elsif m[3] || m[4] then codepoint((m[3] || m[4]).to_i(16), t)
          else
            SIMPLE_ESCAPES.fetch(m[5]) { fail!("invalid escape sequence \"\\#{m[5]}\"", t) }.b
          end
        end
        out
      end

      def codepoint(n, t)
        fail!("invalid Unicode escape", t) if n > 0x10FFFF
        # a lone surrogate has no UTF-8 form; protoc writes it as the three bytes anyway
        if (0xD800..0xDFFF).cover?(n)
          [0xE0 | (n >> 12), 0x80 | ((n >> 6) & 0x3F), 0x80 | (n & 0x3F)].pack("C*")
        else
          [n].pack("U").b
        end
      end

      def enum(info)
        negative = accept("-")
        t = @tokens.next
        if t.type == :identifier && !negative
          number = info.enum_numbers[t.text.to_sym]
          return info.enum_names.fetch(number) if number
          fail!("unknown enumeration value of \"#{t.text}\" for field \"#{info.name}\"", t)
        elsif t.type == :integer
          n = integer_value(t)
          n = -n if negative
          name = info.enum_names[n]
          return name if name
          if info.closed_enum || !Message::Coercion::ENUM_RANGE.cover?(n)
            fail!("unknown enumeration value of \"#{"-" if negative}#{t.text}\" for field \"#{info.name}\"", t)
          end
          n
        else
          fail!("expected an enum name or number, got #{shown(t)}", t)
        end
      end

      def any_expansion(msg, url, token)
        fail!("\"[#{url}]\" expands an Any, but this is a #{msg.class.descriptor.full_name}", token) unless msg.class.descriptor.full_name == ANY
        name = url[(url.rindex("/") + 1)..]
        klass = Types.find(name, registry: @registry)
        fail!("could not find the type \"#{name}\" of an Any", token) unless klass.is_a?(Class)
        accept(":")
        t = @tokens.next
        close = CLOSE[t.text] if t.type == :symbol
        fail!("expected \"{\" or \"<\", got #{shown(t)}", t) unless close
        inner = klass.new
        message_body(inner, close)
        msg.type_url = url
        msg.value = inner.encode
      end

      def extension(msg, name, token, collected)
        field = @extensions.named(msg.class.descriptor, name)
        info = field && @extensions.info(field)
        unless info
          fail!("extension \"#{name}\" is not known to #{msg.class.descriptor.full_name}", token) unless @allow_unknown
          return skip_value
        end
        if !info.repeated && collected.key?(info)
          fail!("non-repeated field \"#{name}\" is specified multiple times", token)
        end
        (collected[info] ||= []).concat(field_values(info, msg.class))
      end

      # Extensions go where the binary codec keeps them, in the unknown fields,
      # in number order as protoc writes them
      def add_extensions(msg, collected)
        collected.sort_by { |info, _| info.number }.each do |info, values|
          @extensions.write(info, values).each { |u| msg.__add_unknown(u) }
        end
        msg.__seal_unknown
      end

      # Skips the value of a field nobody knows: a scalar, a list or a message
      def skip_value
        if accept(":")
          if accept("[")
            list { skip_single }
          else
            skip_single
          end
        else
          skip_message
        end
      end

      def skip_single
        return skip_message if open?
        accept("-")
        t = @tokens.next
        case t.type
        when :string then @tokens.next while @tokens.peek.type == :string
        when :identifier, :integer, :float then nil
        else fail!("unexpected #{shown(t)}", t)
        end
      end

      def skip_message
        t = @tokens.next
        close = CLOSE[t.text] if t.type == :symbol
        fail!("expected \"{\" or \"<\", got #{shown(t)}", t) unless close
        until accept(close)
          n = @tokens.next
          fail!("expected \"#{close}\", got end of input", n) if n.type == :eof
          if n.type == :symbol && n.text == "["
            @tokens.next until accept("]") || @tokens.peek.type == :eof
          elsif n.type != :identifier
            fail!("expected a field name, got #{shown(n)}", n)
          end
          skip_value
          accept(";") || accept(",")
        end
      end
    end
  end
end
