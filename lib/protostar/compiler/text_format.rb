# frozen_string_literal: true

module Protostar
  class Compiler
    # Just enough of protoc's text-format parser to read aggregate option
    # values (`option (opt) = { a: 1 b { c: "x" } [ext]: 2 };`) into option
    # entries, with protoc's error messages for the common mistakes.
    #
    # @api private
    class TextFormat
      ANY_PREFIXES = ["type.googleapis.com/", "type.googleprod.com/"].freeze
      INT32_MAX = 2**31 - 1
      INT64_MAX = 2**63 - 1
      UINT32_MAX = 2**32 - 1
      UINT64_MAX = 2**64 - 1
      RECURSION_LIMIT = 100

      # @return [Array<String>]
      attr_reader :errors

      # @param text [String] the aggregate value, braces excluded
      # @param type [Schema::Message]
      # @param interpreter [OptionInterpreter] maps symbols to descriptors
      # @param table [SymbolTable] resolves `[extension]` names
      def initialize(text, type, interpreter, table)
        @type = type
        @interpreter = interpreter
        @table = table
        @errors = []
        @lexer = Lexer.new(text, ->(_line, _column, message) { @errors << message })
        @lexer.next
        @depth = RECURSION_LIMIT
      end

      # @return [Array, nil] the entries, or nil after errors
      def parse
        entries = []
        until looking_at_type?(:end)
          return nil unless consume_field(@type, entries)
        end
        @errors.empty? ? entries : nil
      end

      private

      def looking_at?(text)
        @lexer.current.text == text
      end

      def looking_at_type?(type)
        @lexer.current.type == type
      end

      def try_consume(text)
        return false unless looking_at?(text)
        @lexer.next
        true
      end

      def consume(text)
        return true if try_consume(text)
        error("Expected \"#{text}\", found \"#{@lexer.current.text}\".")
      end

      def error(message)
        @errors << message
        false
      end

      def consume_message(type, delimiter, entries)
        @depth -= 1
        return error("Message is too deep, the parser exceeded the configured recursion limit of #{RECURSION_LIMIT}.") if @depth < 0
        until looking_at?(">") || looking_at?("}")
          return false unless consume_field(type, entries)
        end
        consume(delimiter)
      ensure
        @depth += 1
      end

      def message_delimiter
        return ">" if try_consume("<")
        consume("{") ? "}" : nil
      end

      # The text between brackets, URL characters included
      def bracketed_name
        consume("[")
        name = +""
        until looking_at?("]") || looking_at_type?(:end)
          name << @lexer.current.text
          @lexer.next
        end
        return nil unless consume("]")
        name
      end

      def consume_field(type, entries)
        if type.full_name == "google.protobuf.Any" && looking_at?("[")
          return consume_any(type, entries)
        end

        if looking_at?("[")
          name = bracketed_name
          return false unless name
          return error("Extension name contains \"/\"") if name.include?("/")
          field = find_extension(type, name)
          unless field
            return error("Extension \"#{name}\" is not defined or is not an extension of \"#{type.full_name}\".")
          end
        else
          unless looking_at_type?(:identifier)
            return error("Expected identifier, got: #{@lexer.current.text}")
          end
          name = @lexer.current.text.dup.force_encoding(Encoding::UTF_8)
          @lexer.next
          field = type.fields_by_name[name]
          if field.nil?
            lower = type.fields_by_name[name.downcase]
            field = lower if lower && group_like?(lower) && lower.message_type.name == name
          end
          return error("Message type \"#{type.full_name}\" has no field named \"#{name}\".") unless field
        end

        if !field.repeated? && entries.any? { |f, _| f.equal?(field) }
          return error("Non-repeated field \"#{name}\" is specified multiple times.")
        end
        if (oneof = field.real_oneof) && (other = entries.find { |f, _| f.real_oneof.equal?(oneof) })
          return error("Field \"#{name}\" is specified along with field \"#{other[0].name}\", another member of " \
            "oneof \"#{oneof.name}\".")
        end

        message = field.type == :message || field.type == :group
        if message
          try_consume(":")
        else
          return false unless consume(":")
        end

        if field.repeated? && try_consume("[")
          unless try_consume("]")
            loop do
              value = message ? field_message(field) : field_value(field)
              return false if value.nil?
              entries << [field, value]
              break if try_consume("]")
              return false unless consume(",")
            end
          end
        else
          value = message ? field_message(field) : field_value(field)
          return false if value.nil?
          entries << [field, value]
        end
        try_consume(";") || try_consume(",")
        true
      end

      def group_like?(field)
        return false unless field.type == :group
        return false unless field.name == field.message_type.name.downcase
        return false unless field.message_type.file.equal?(field.file)
        scope = field.extension? ? field.containing_message : field.containing_message
        field.message_type.containing_message.equal?(scope)
      end

      def find_extension(type, name)
        symbol = @table.lookup(name, type.full_name)
        if symbol&.kind == :field
          field = @interpreter.schema_of(symbol)
          return field if field.extension? && field.extendee.full_name == type.full_name
          return nil
        end
        if symbol&.kind == :message && type.message_set_wire_format?
          foreign = @interpreter.schema_of(symbol)
          return foreign.extensions.find do |ext|
            ext.extendee.full_name == type.full_name && ext.type == :message && ext.label == :optional &&
              ext.message_type.equal?(foreign)
          end
        end
        nil
      end

      def field_message(field)
        delimiter = message_delimiter
        return nil unless delimiter
        entries = []
        return nil unless consume_message(field.message_type, delimiter, entries)
        entries
      end

      def consume_any(type, entries)
        text = bracketed_name
        return false unless text
        slash = text.rindex("/")
        return error("Type URL prefix is missing") unless slash
        prefix = text[0..slash]
        full_name = text[(slash + 1)..]
        try_consume(":")
        target = nil
        if ANY_PREFIXES.include?(prefix)
          symbol = @table.find(full_name)
          target = @interpreter.schema_of(symbol) if symbol&.kind == :message
        end
        return error("Could not find type \"#{text}\" stored in google.protobuf.Any.") unless target
        delimiter = message_delimiter
        return false unless delimiter
        inner = []
        return false unless consume_message(target, delimiter, inner)
        if entries.any? { |f, _| f.number == 1 || f.number == 2 }
          return error("Non-repeated Any specified multiple times.")
        end
        entries << [type.field(1), text]
        entries << [type.field(2), WireEncoder.encode(target, @interpreter.fold(inner))]
        try_consume(";") || try_consume(",")
        true
      end

      def field_value(field)
        case field.type
        when :int32, :sint32, :sfixed32 then signed_integer(INT32_MAX)
        when :int64, :sint64, :sfixed64 then signed_integer(INT64_MAX)
        when :uint32, :fixed32 then unsigned_integer(UINT32_MAX)
        when :uint64, :fixed64 then unsigned_integer(UINT64_MAX)
        when :float
          v = double
          v.nil? ? nil : Schema::DefaultValue.to_float32(v)
        when :double then double
        when :string, :bytes
          unless looking_at_type?(:string)
            error("Expected string, got: #{@lexer.current.text}")
            return nil
          end
          out = "".b
          while looking_at_type?(:string)
            Lexer.parse_string(@lexer.current.text, out)
            @lexer.next
          end
          (field.type == :string) ? out.force_encoding(Encoding::UTF_8) : out
        when :bool
          if looking_at_type?(:integer)
            v = unsigned_integer(1)
            return v.nil? ? nil : v == 1
          end
          unless looking_at_type?(:identifier)
            error("Expected identifier, got: #{@lexer.current.text}")
            return nil
          end
          text = @lexer.current.text
          @lexer.next
          case text
          when "true", "True", "t" then true
          when "false", "False", "f" then false
          else
            error("Invalid value for boolean field \"#{field.name}\". Value: \"#{text}\".")
            nil
          end
        when :enum then enum_value(field)
        end
      end

      def enum_value(field)
        enum = field.enum_type
        if looking_at_type?(:identifier)
          text = @lexer.current.text
          @lexer.next
          value = enum.values_by_name[text]
        elsif looking_at?("-") || looking_at_type?(:integer)
          number = signed_integer(INT32_MAX)
          return nil if number.nil?
          text = number.to_s
          value = enum.value(number)
          return number if value.nil? && !enum.closed?
        else
          error("Expected integer or identifier, got: #{@lexer.current.text}")
          return nil
        end
        unless value
          error("Unknown enumeration value of \"#{text}\" for field \"#{field.name}\".")
          return nil
        end
        enum.values_by_number.fetch(value.number).name.to_sym
      end

      def unsigned_integer(max)
        unless looking_at_type?(:integer)
          error("Expected integer, got: #{@lexer.current.text}")
          return nil
        end
        value = Lexer.parse_integer(@lexer.current.text, max)
        unless value
          error("Integer out of range (#{@lexer.current.text})")
          return nil
        end
        @lexer.next
        value
      end

      def signed_integer(max)
        negative = try_consume("-")
        value = unsigned_integer(negative ? max + 1 : max)
        return nil if value.nil?
        negative ? -value : value
      end

      def double
        negative = try_consume("-")
        token = @lexer.current
        value = case token.type
        when :integer
          if token.text.match?(/\A0[xX]/) || token.text.match?(/\A0\d/)
            error("Expect a decimal number, got: #{token.text}")
            return nil
          end
          int = Lexer.parse_integer(token.text, UINT64_MAX)
          @lexer.next
          int ? int.to_f : Lexer.parse_float(token.text)
        when :float
          @lexer.next
          Lexer.parse_float(token.text)
        when :identifier
          text = token.text.downcase
          if text == "inf" || text == "infinity"
            @lexer.next
            Float::INFINITY
          elsif text == "nan"
            @lexer.next
            Float::NAN
          else
            error("Expected double, got: #{text}")
            return nil
          end
        else
          error("Expected double, got: #{token.text}")
          return nil
        end
        negative ? -value : value
      end
    end

    # Encodes a folded option message to protobuf wire format, as protoc
    # serializes the message inside an `Any` written in an aggregate
    # @api private
    module WireEncoder
      WIRE = {
        int32: 0, int64: 0, uint32: 0, uint64: 0, sint32: 0, sint64: 0, bool: 0, enum: 0,
        fixed64: 1, sfixed64: 1, double: 1, string: 2, bytes: 2, message: 2, group: 3,
        fixed32: 5, sfixed32: 5, float: 5
      }.freeze

      def self.encode(type, hash)
        out = "".b
        fields = type.fields.map { |f| [f, hash[f.name.to_sym]] }
        (hash[:__extensions] || {}).each do |name, value|
          ext = type.file.all_extensions.find { |e| e.full_name == name } ||
            type.extensions.find { |e| e.full_name == name }
          fields << [ext, value] if ext
        end
        fields.sort_by { |f, _| f.number }.each do |field, value|
          next if value.nil?
          if field.repeated?
            if field.packed? && WIRE[field.type] != 2 && WIRE[field.type] != 3
              body = "".b
              value.each { |v| body << scalar(field, v) }
              out << tag(field.number, 2) << varint(body.bytesize) << body
            else
              value.each { |v| out << one(field, v) }
            end
          else
            out << one(field, value)
          end
        end
        out
      end

      def self.one(field, value)
        wire = WIRE.fetch(field.type)
        case field.type
        when :message
          body = encode(field.message_type, value)
          tag(field.number, 2) << varint(body.bytesize) << body
        when :group
          tag(field.number, 3) << encode(field.message_type, value) << tag(field.number, 4)
        when :string, :bytes
          bytes = value.b
          tag(field.number, 2) << varint(bytes.bytesize) << bytes
        else
          tag(field.number, wire) << scalar(field, value)
        end
      end

      def self.scalar(field, value)
        case field.type
        when :int32, :int64, :uint32, :uint64 then varint(value & 0xFFFFFFFFFFFFFFFF)
        when :sint32, :sint64 then varint((value << 1) ^ (value >> 63))
        when :bool then varint(value ? 1 : 0)
        when :enum
          number = value.is_a?(Symbol) ? field.enum_type.value(value.to_s).number : value
          varint(number & 0xFFFFFFFFFFFFFFFF)
        when :fixed64 then [value].pack("Q<")
        when :sfixed64 then [value].pack("q<")
        when :double then [value].pack("E")
        when :fixed32 then [value].pack("L<")
        when :sfixed32 then [value].pack("l<")
        when :float then [value].pack("e")
        end
      end

      def self.tag(number, wire)
        varint((number << 3) | wire)
      end

      def self.varint(value)
        out = "".b
        loop do
          byte = value & 0x7F
          value >>= 7
          if value.zero?
            out << byte
            return out
          end
          out << (byte | 0x80)
        end
      end
    end
  end
end
