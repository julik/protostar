# frozen_string_literal: true

module Protostar
  class Compiler
    # protoc's `.proto` parser (`compiler/parser.cc`). Produces an AST::File
    # shaped like the parser's FileDescriptorProto, the source locations protoc
    # records, and protoc's parse errors with its recovery (skip to the end of
    # the statement or block and carry on).
    class Parser # :nodoc: all
      TYPES = {
        "double" => :TYPE_DOUBLE, "float" => :TYPE_FLOAT, "uint64" => :TYPE_UINT64, "fixed64" => :TYPE_FIXED64,
        "fixed32" => :TYPE_FIXED32, "bool" => :TYPE_BOOL, "string" => :TYPE_STRING, "group" => :TYPE_GROUP,
        "bytes" => :TYPE_BYTES, "uint32" => :TYPE_UINT32, "sfixed32" => :TYPE_SFIXED32,
        "sfixed64" => :TYPE_SFIXED64, "int32" => :TYPE_INT32, "int64" => :TYPE_INT64,
        "sint32" => :TYPE_SINT32, "sint64" => :TYPE_SINT64
      }.freeze

      # EDITION_UNSTABLE spells integer types by their wire format
      UNSTABLE_TYPES = {
        "double" => :TYPE_DOUBLE, "float" => :TYPE_FLOAT, "uint64" => :TYPE_FIXED64, "bool" => :TYPE_BOOL,
        "string" => :TYPE_STRING, "group" => :TYPE_GROUP, "bytes" => :TYPE_BYTES, "uint32" => :TYPE_FIXED32,
        "int32" => :TYPE_SFIXED32, "int64" => :TYPE_SFIXED64, "varint32" => :TYPE_INT32,
        "varint64" => :TYPE_INT64, "uvarint32" => :TYPE_UINT32, "uvarint64" => :TYPE_UINT64,
        "zigzag32" => :TYPE_SINT32, "zigzag64" => :TYPE_SINT64
      }.freeze

      UNSTABLE_REPLACEMENTS = {
        "fixed32" => "uint32", "fixed64" => "uint64", "sfixed32" => "int32", "sfixed64" => "int64",
        "sint32" => "zigzag32", "sint64" => "zigzag64"
      }.freeze

      INT32_MAX = 2**31 - 1
      INT64_MAX = 2**63 - 1
      UINT32_MAX = 2**32 - 1
      UINT64_MAX = 2**64 - 1
      MAX_FIELD_NUMBER = 536_870_911
      MAX_NESTING = 32
      # end of a `to max` range until the message's maximum is known
      MAX_RANGE_SENTINEL = -1

      # descriptor.proto field numbers used in source paths
      FILE_PACKAGE = 2
      FILE_DEPENDENCY = 3
      FILE_MESSAGE_TYPE = 4
      FILE_ENUM_TYPE = 5
      FILE_SERVICE = 6
      FILE_EXTENSION = 7
      FILE_OPTIONS = 8
      FILE_PUBLIC_DEPENDENCY = 10
      FILE_WEAK_DEPENDENCY = 11
      FILE_SYNTAX = 12
      FILE_OPTION_DEPENDENCY = 15
      MESSAGE_NAME = 1
      MESSAGE_FIELD = 2
      MESSAGE_NESTED_TYPE = 3
      MESSAGE_ENUM_TYPE = 4
      MESSAGE_EXTENSION_RANGE = 5
      MESSAGE_EXTENSION = 6
      MESSAGE_OPTIONS = 7
      MESSAGE_ONEOF_DECL = 8
      MESSAGE_RESERVED_RANGE = 9
      MESSAGE_RESERVED_NAME = 10
      RANGE_START = 1
      RANGE_END = 2
      RANGE_OPTIONS = 3
      FIELD_NAME = 1
      FIELD_EXTENDEE = 2
      FIELD_NUMBER = 3
      FIELD_LABEL = 4
      FIELD_TYPE = 5
      FIELD_TYPE_NAME = 6
      FIELD_DEFAULT_VALUE = 7
      FIELD_OPTIONS = 8
      FIELD_JSON_NAME = 10
      ONEOF_NAME = 1
      ONEOF_OPTIONS = 2
      ENUM_NAME = 1
      ENUM_VALUE = 2
      ENUM_OPTIONS = 3
      ENUM_RESERVED_RANGE = 4
      ENUM_RESERVED_NAME = 5
      ENUM_VALUE_NAME = 1
      ENUM_VALUE_NUMBER = 2
      ENUM_VALUE_OPTIONS = 3
      SERVICE_NAME = 1
      SERVICE_METHOD = 2
      SERVICE_OPTIONS = 3
      METHOD_NAME = 1
      METHOD_INPUT_TYPE = 2
      METHOD_OUTPUT_TYPE = 3
      METHOD_OPTIONS = 4
      METHOD_CLIENT_STREAMING = 5
      METHOD_SERVER_STREAMING = 6
      UNINTERPRETED_OPTION = 999
      OPTION_NAME = 2
      OPTION_IDENTIFIER_VALUE = 3
      OPTION_POSITIVE_INT_VALUE = 4
      OPTION_NEGATIVE_INT_VALUE = 5
      OPTION_DOUBLE_VALUE = 6
      OPTION_STRING_VALUE = 7
      OPTION_AGGREGATE_VALUE = 8
      NAME_PART = 1

      # 0-based errors, lexer's included.
      attr_reader :errors #: Array[[Integer, Integer, String]]
      attr_reader :warnings #: Array[[Integer, Integer, String]]
      # "proto2", "proto3" or "editions" once parsed.
      attr_reader :syntax_identifier #: String

      # - `require_syntax`: reject files without `syntax` or `edition`
      #: (String source, ?require_syntax: bool) -> void
      def initialize(source, require_syntax: false)
        @errors = []
        @warnings = []
        @lexer = Lexer.new(source, ->(line, column, message) { @errors << [line, column, message] })
        @require_syntax = require_syntax
        @syntax_identifier = ""
        @edition = :EDITION_UNKNOWN
        @upcoming_doc_comments = +""
        @upcoming_detached_comments = []
        @recursion_depth = MAX_NESTING
      end

      # - `name`: the file name to record
      #
      # Returns the tree, complete as far as parsing got.
      #: (?String? name) -> AST::File
      def parse(name = nil)
        file = AST::File.new
        file.name = name
        @file = file
        @locations = file.locations
        if looking_at_type?(:start)
          @lexer.next_with_comments(nil, @upcoming_detached_comments, @upcoming_doc_comments)
        end

        root = SourceInfo::Recorder.new(@lexer, [], @locations)
        begin
          root.record_legacy(file, :other)
          if @require_syntax || looking_at?("syntax") || looking_at?("edition")
            return file unless parse_syntax_identifier(file, root)
            file.syntax = @syntax_identifier
            file.edition = @edition if @syntax_identifier == "editions"
          else
            @syntax_identifier = "proto2"
          end

          until at_end?
            next if parse_top_level_statement(file, root)
            skip_statement
            if looking_at?("}")
              record_error("Unmatched \"}\".")
              @lexer.next_with_comments(nil, @upcoming_detached_comments, @upcoming_doc_comments)
            end
          end
        ensure
          root.finish
        end
        file
      end

      # Returns whether parsing went without errors.
      #: () -> bool
      def success?
        @errors.empty?
      end

      # Returns the token parsing stopped at.
      #: () -> Lexer::Token
      def current_token
        @lexer.current
      end

      private

      def looking_at?(text)
        @lexer.current.text == text
      end

      def looking_at_type?(type)
        @lexer.current.type == type
      end

      def at_end?
        looking_at_type?(:end)
      end

      def try_consume(text)
        return false unless looking_at?(text)
        @lexer.next
        true
      end

      def consume(text, error = nil)
        return true if try_consume(text)
        record_error(error || "Expected \"#{text}\".")
        false
      end

      #: (untyped error) -> String?
      def consume_identifier(error)
        if looking_at_type?(:identifier)
          text = @lexer.current.text.dup.force_encoding(Encoding::UTF_8)
          @lexer.next
          return text
        end
        record_error(error)
        nil
      end

      # Parser::ConsumeInteger: an unsigned int32
      #: (untyped error) -> Integer?
      def consume_integer(error)
        if looking_at_type?(:integer)
          value = Lexer.parse_integer(@lexer.current.text, INT32_MAX)
          unless value
            record_error("Integer out of range.")
            value = 0
          end
          @lexer.next
          return value
        end
        record_error(error)
        nil
      end

      # Returns an int32, sign included.
      #: (untyped error) -> Integer?
      def consume_signed_integer(error)
        negative = false
        max = INT32_MAX
        if try_consume("-")
          negative = true
          max += 1
        end
        value = consume_integer64(max, error)
        return nil if value.nil?
        negative ? -value : value
      end

      def consume_integer64(max, error)
        if looking_at_type?(:integer)
          value = Lexer.parse_integer(@lexer.current.text, max)
          unless value
            record_error("Integer out of range.")
            value = 0
          end
          @lexer.next
          return value
        end
        record_error(error)
        nil
      end

      def try_consume_integer64(max)
        return nil unless looking_at_type?(:integer)
        value = Lexer.parse_integer(@lexer.current.text, max)
        return nil unless value
        @lexer.next
        value
      end

      #: (untyped error) -> Float?
      def consume_number(error)
        token = @lexer.current
        if token.type == :float
          value = Lexer.parse_float(token.text)
          @lexer.next
          value
        elsif token.type == :integer
          value = Lexer.parse_integer(token.text, UINT64_MAX)
          if value
            value = value.to_f
          elsif token.text.start_with?("0")
            record_error("Integer out of range.")
            value = 0.0
          elsif Lexer.float_text?(token.text)
            value = Lexer.parse_float(token.text)
          else
            record_error("Integer out of range.")
            value = 0.0
          end
          @lexer.next
          value
        elsif looking_at?("inf")
          @lexer.next
          Float::INFINITY
        elsif looking_at?("nan")
          @lexer.next
          Float::NAN
        else
          record_error(error)
          nil
        end
      end

      # Returns a binary String, adjacent literals concatenated.
      #: (untyped error) -> String?
      def consume_string(error)
        unless looking_at_type?(:string)
          record_error(error)
          return nil
        end
        out = "".b
        Lexer.parse_string(@lexer.current.text, out)
        @lexer.next
        while looking_at_type?(:string)
          Lexer.parse_string(@lexer.current.text, out)
          @lexer.next
        end
        out
      end

      def try_consume_end_of_declaration(text, location)
        return false unless looking_at?(text)
        leading = +""
        trailing = +""
        detached = []
        @lexer.next_with_comments(trailing, detached, leading)
        leading, @upcoming_doc_comments = @upcoming_doc_comments, leading
        if location
          detached, @upcoming_detached_comments = @upcoming_detached_comments, detached
          location.attach_comments(leading, trailing, detached)
        elsif text == "}"
          @upcoming_detached_comments = detached
        else
          @upcoming_detached_comments.concat(detached)
        end
        true
      end

      def consume_end_of_declaration(text, location)
        return true if try_consume_end_of_declaration(text, location)
        record_error("Expected \"#{text}\".")
        false
      end

      def record_error(message)
        @errors << [@lexer.current.line, @lexer.current.column, message]
      end

      def record_error_at(line, column, message)
        @errors << [line, column, message]
      end

      def record_warning_at(line, column, message)
        @warnings << [line, column, message]
      end

      # Runs the block with a location that is finished however the block exits
      #: [T] (untyped recorder) { (untyped) -> T } -> T
      def scoped(recorder)
        yield recorder
      ensure
        recorder.finish
      end

      def skip_statement
        loop do
          return if at_end?
          if looking_at_type?(:symbol)
            return if try_consume_end_of_declaration(";", nil)
            if try_consume("{")
              skip_rest_of_block
              return
            end
            return if looking_at?("}")
          end
          @lexer.next
        end
      end

      def skip_rest_of_block
        depth = 1
        loop do
          return if at_end?
          if looking_at_type?(:symbol)
            if try_consume_end_of_declaration("}", nil)
              depth -= 1
              return if depth == 0
            elsif try_consume("{")
              depth += 1
            end
          end
          @lexer.next
        end
      end

      def validate_message(message)
        message.options&.uninterpreted&.each do |option|
          next unless !option.name.empty? && !option.name[0][1] && option.name[0][0] == "map_entry"
          line, column = option.position(:option_name) || [-1, 0]
          record_error_at(line, column, "map_entry should not be set explicitly. Use map<KeyType, ValueType> instead.")
          return false
        end
        true
      end

      def validate_enum(enum)
        has_allow_alias = false
        allow_alias = false
        enum.options&.uninterpreted&.each do |option|
          next if option.name.size > 1
          next unless !option.name[0][1] && option.name[0][0] == "allow_alias"
          has_allow_alias = true
          allow_alias = true if option.value_kind == :identifier_value && option.value == "true"
          break
        end
        if has_allow_alias && !allow_alias
          record_error("\"#{enum.name}\" declares 'option allow_alias = false;' which has no effect. " \
            "Please remove the declaration.")
          return false
        end
        numbers = enum.value.map(&:number)
        if allow_alias && numbers.uniq.size == numbers.size
          record_error("\"#{enum.name}\" declares support for enum aliases but no enum values share field " \
            "numbers. Please remove the unnecessary 'option allow_alias = true;' declaration.")
          return false
        end
        true
      end

      def parse_syntax_identifier(file, parent)
        scoped(parent.child(FILE_SYNTAX)) do |location|
          location.record_legacy(file, :editions)
          has_edition = false
          if try_consume("edition")
            has_edition = true
          else
            return false unless consume("syntax",
              "File must begin with an edition or syntax statement, e.g. 'edition = \"2023\";'.")
          end
          return false unless consume("=")
          token = @lexer.current.dup
          syntax = consume_string("Expected syntax identifier.")
          return false if syntax.nil?
          syntax = syntax.force_encoding(Encoding::UTF_8)
          return false unless consume_end_of_declaration(";", location)

          if has_edition
            edition = :"EDITION_#{syntax}"
            if !Schema::Features::EDITIONS.key?(edition) ||
                %i[EDITION_PROTO2 EDITION_PROTO3 EDITION_UNKNOWN].include?(edition)
              record_error_at(token.line, token.column, "Unknown edition \"#{syntax}\".")
              return false
            end
            @edition = edition
            @syntax_identifier = "editions"
            return true
          end

          @syntax_identifier = syntax
          if syntax != "proto2" && syntax != "proto3"
            record_error_at(token.line, token.column, "Unrecognized syntax identifier \"#{syntax}\".  This parser " \
              "only recognizes \"proto2\" and \"proto3\".")
            return false
          end
          true
        end
      end

      def edition_number
        Schema::Features::EDITIONS.fetch(@edition, 0)
      end

      def parse_top_level_statement(file, root)
        return true if try_consume_end_of_declaration(";", nil)
        visibility = nil
        if looking_at?("export") || looking_at?("local")
          ok, visibility = parse_visibility(file)
          return false unless ok
        end

        if looking_at?("message")
          @recursion_depth = MAX_NESTING
          message = AST::Message.new
          scoped(root.child(FILE_MESSAGE_TYPE, file.message_type.size)) do |location|
            file.message_type << message
            parse_message_definition(message, visibility, location)
          end
        elsif looking_at?("enum")
          enum = AST::Enum.new
          scoped(root.child(FILE_ENUM_TYPE, file.enum_type.size)) do |location|
            file.enum_type << enum
            parse_enum_definition(enum, visibility, location)
          end
        elsif looking_at?("service")
          service = AST::Service.new
          scoped(root.child(FILE_SERVICE, file.service.size)) do |location|
            file.service << service
            parse_service_definition(service, location)
          end
        elsif looking_at?("extend")
          scoped(root.child(FILE_EXTENSION)) do |location|
            parse_extend(file.extension, file.message_type, root, FILE_MESSAGE_TYPE, location)
          end
        elsif looking_at?("import")
          parse_import(file, root)
        elsif looking_at?("package")
          parse_package(file, root)
        elsif looking_at?("option")
          scoped(root.child(FILE_OPTIONS)) do |location|
            parse_option(file, location, :statement)
          end
        else
          record_error("Expected top-level statement (e.g. \"message\").")
          false
        end
      end

      # protoc's GenerateSyntheticOneofs
      def generate_synthetic_oneofs(message)
        fields = message.field.select(&:proto3_optional)
        return if fields.empty?
        taken = message.field.map(&:name) + message.oneof_decl.map(&:name)
        names = Schema::Draft.synthetic_oneof_names(fields.map { |f| f.name.to_s }, taken)
        fields.zip(names) do |field, name|
          field.oneof_index = message.oneof_decl.size
          oneof = AST::Oneof.new
          oneof.name = name
          message.oneof_decl << oneof
        end
      end

      def parse_message_definition(message, visibility, message_location)
        @recursion_depth -= 1
        begin
          if @recursion_depth <= 0
            record_error("Reached maximum recursion limit for nested messages.")
            return false
          end
          return false unless consume("message")
          scoped(message_location.child(MESSAGE_NAME)) do |location|
            location.record_legacy(message, :name)
            name = consume_identifier("Expected message name.")
            return false if name.nil?
            message.name = name
          end
          return false unless parse_message_block(message, message_location)
          generate_synthetic_oneofs(message) if @syntax_identifier == "proto3"
          message.visibility = visibility if visibility
          true
        ensure
          @recursion_depth += 1
        end
      end

      def message_set?(message)
        message.options&.uninterpreted&.any? do |o|
          o.name.size == 1 && !o.name[0][1] && o.name[0][0] == "message_set_wire_format" &&
            o.value_kind == :identifier_value && o.value == "true"
        end
      end

      def adjust_max_ranges(message, ranges)
        max = message_set?(message) ? INT32_MAX : MAX_FIELD_NUMBER + 1
        ranges.each { |r| r.end = max if r.end == MAX_RANGE_SENTINEL }
      end

      def parse_message_block(message, message_location)
        return false unless consume_end_of_declaration("{", message_location)
        until try_consume_end_of_declaration("}", nil)
          if at_end?
            record_error("Reached end of input in message definition (missing '}').")
            return false
          end
          skip_statement unless parse_message_statement(message, message_location)
        end
        adjust_max_ranges(message, message.extension_range) unless message.extension_range.empty?
        adjust_max_ranges(message, message.reserved_range) unless message.reserved_range.empty?
        validate_message(message)
      end

      def parse_message_statement(message, message_location)
        return true if try_consume_end_of_declaration(";", nil)
        visibility = nil
        if looking_at?("export") || looking_at?("local")
          ok, visibility = parse_visibility(@file)
          return false unless ok
        end

        if looking_at?("message")
          nested = AST::Message.new
          scoped(message_location.child(MESSAGE_NESTED_TYPE, message.nested_type.size)) do |location|
            message.nested_type << nested
            parse_message_definition(nested, visibility, location)
          end
        elsif looking_at?("enum")
          enum = AST::Enum.new
          scoped(message_location.child(MESSAGE_ENUM_TYPE, message.enum_type.size)) do |location|
            message.enum_type << enum
            parse_enum_definition(enum, visibility, location)
          end
        elsif looking_at?("extensions")
          scoped(message_location.child(MESSAGE_EXTENSION_RANGE)) do |location|
            parse_extensions(message, location)
          end
        elsif looking_at?("reserved")
          parse_message_reserved(message, message_location)
        elsif looking_at?("extend")
          scoped(message_location.child(MESSAGE_EXTENSION)) do |location|
            parse_extend(message.extension, message.nested_type, message_location, MESSAGE_NESTED_TYPE, location)
          end
        elsif looking_at?("option")
          scoped(message_location.child(MESSAGE_OPTIONS)) do |location|
            parse_option(message, location, :statement)
          end
        elsif looking_at?("oneof")
          index = message.oneof_decl.size
          oneof = AST::Oneof.new
          scoped(message_location.child(MESSAGE_ONEOF_DECL, index)) do |location|
            message.oneof_decl << oneof
            parse_oneof(oneof, message, index, location, message_location)
          end
        else
          field = AST::Field.new
          scoped(message_location.child(MESSAGE_FIELD, message.field.size)) do |location|
            message.field << field
            parse_message_field(field, message.nested_type, message_location, MESSAGE_NESTED_TYPE, location)
          end
        end
      end

      def parse_message_field(field, messages, parent_location, nested_type_number, field_location)
        label = parse_label(field_location)
        if label
          field.label = label
          field.proto3_optional = true if label == :LABEL_OPTIONAL && @syntax_identifier == "proto3"
        end
        parse_message_field_no_label(field, messages, parent_location, nested_type_number, field_location)
      end

      def default_to_optional_fields?
        @syntax_identifier == "editions" || @syntax_identifier == "proto3"
      end

      def parse_message_field_no_label(field, messages, parent_location, nested_type_number, field_location)
        map_field = nil
        scoped(field_location.child) do |location|
          location.record_legacy(field, :type)
          type_parsed = false
          type = :TYPE_INT32
          type_name = ""
          if try_consume("map")
            if looking_at?("<")
              map_field = {}
              return false unless parse_map_type(map_field, field, location)
            else
              type_parsed = true
              type_name = "map"
            end
          end
          unless map_field
            field.label = :LABEL_OPTIONAL if field.label.nil? && default_to_optional_fields?
            if field.label.nil?
              record_error("Expected \"required\", \"optional\", or \"repeated\".")
              field.label = :LABEL_OPTIONAL
            end
            unless type_parsed
              parsed = parse_type
              return false unless parsed
              type, type_name = parsed
            end
            if type_name.empty?
              location.add_path(FIELD_TYPE)
              field.type = type
            else
              location.add_path(FIELD_TYPE_NAME)
              field.type_name = type_name
            end
          end
        end

        name_token = @lexer.current.dup
        scoped(field_location.child(FIELD_NAME)) do |location|
          location.record_legacy(field, :name)
          name = consume_identifier("Expected field name.")
          return false if name.nil?
          field.name = name
        end
        return false unless consume("=", "Missing field number.")
        scoped(field_location.child(FIELD_NUMBER)) do |location|
          location.record_legacy(field, :number)
          number = consume_integer("Expected field number.")
          return false if number.nil?
          field.number = number
        end
        return false unless parse_field_options(field, field_location)

        if field.type == :TYPE_GROUP
          group = AST::Message.new
          group_location = parent_location.child
          begin
            group_location.start_at_recorder(field_location)
            group_location.add_path(nested_type_number)
            group_location.add_path(messages.size)
            messages << group
            group.name = field.name
            scoped(group_location.child(MESSAGE_NAME)) do |location|
              location.start_at(name_token)
              location.end_at(name_token)
              location.record_legacy(group, :name)
            end
            scoped(field_location.child(FIELD_TYPE_NAME)) do |location|
              location.start_at(name_token)
              location.end_at(name_token)
            end
            first = group.name.getbyte(0)
            if first.nil? || first < 65 || first > 90
              record_error_at(name_token.line, name_token.column, "Group names must start with a capital letter.")
            end
            field.name = Schema::Draft.group_field_name(field.name)
            field.type_name = group.name
            if looking_at?("{")
              return false unless parse_message_block(group, group_location)
            else
              record_error("Missing group body.")
              return false
            end
          ensure
            group_location.finish
          end
        else
          return false unless consume_end_of_declaration(";", field_location)
        end

        generate_map_entry(map_field, field, messages) if map_field
        true
      end

      def parse_map_type(map_field, field, location)
        if field.oneof_index
          record_error("Map fields are not allowed in oneofs.")
          return false
        end
        if field.label
          record_error("Field labels (required/optional/repeated) are not allowed on map fields.")
          return false
        end
        if field.extendee
          record_error("Map fields are not allowed to be extensions.")
          return false
        end
        field.label = :LABEL_REPEATED
        return false unless consume("<")
        key = parse_type
        return false unless key
        return false unless consume(",")
        value = parse_type
        return false unless value
        return false unless consume(">")
        map_field[:key] = key
        map_field[:value] = value
        location.add_path(FIELD_TYPE_NAME)
        true
      end

      def generate_map_entry(map_field, field, messages)
        entry = AST::Message.new
        messages << entry
        entry_name = Schema::Draft.map_entry_name(field.name)
        field.type_name = entry_name
        entry.name = entry_name
        entry.options = AST::Options.new
        entry.options.known[:map_entry] = true
        key = map_entry_field("key", 1, map_field[:key])
        value = map_entry_field("value", 2, map_field[:value])
        entry.field << key << value
        field.options&.uninterpreted&.each do |option|
          first, ext = option.name[0]
          if option.name.size == 1 && first == "enforce_utf8" && !ext
            (key.options ||= AST::Options.new).uninterpreted << option if key.type == :TYPE_STRING
            (value.options ||= AST::Options.new).uninterpreted << option if value.type == :TYPE_STRING
          end
          if first == "features" && !ext
            (key.options ||= AST::Options.new).uninterpreted << option
            (value.options ||= AST::Options.new).uninterpreted << option
          end
        end
      end

      #: (String name, Integer number, [Symbol?, String?]) -> untyped
      def map_entry_field(name, number, (type, type_name))
        f = AST::Field.new
        f.name = name
        f.label = :LABEL_OPTIONAL
        f.number = number
        if type_name.empty?
          f.type = type
        else
          f.type_name = type_name
        end
        f
      end

      def parse_field_options(field, field_location)
        return true unless looking_at?("[")
        scoped(field_location.child(FIELD_OPTIONS)) do |location|
          return false unless consume("[")
          loop do
            if looking_at?("default")
              return false unless parse_default_assignment(field, field_location)
            elsif looking_at?("json_name")
              return false unless parse_json_name(field, field_location)
            else
              return false unless parse_option(field, location, :assignment)
            end
            break unless try_consume(",")
          end
          return false unless consume("]")
        end
        true
      end

      def parse_default_assignment(field, field_location)
        if field.default_value
          record_error("Already set option \"default\".")
          field.default_value = nil
        end
        return false unless consume("default")
        return false unless consume("=")
        scoped(field_location.child(FIELD_DEFAULT_VALUE)) do |location|
          location.record_legacy(field, :default_value)
          unless field.type
            field.default_value = @lexer.current.text.dup.force_encoding(Encoding::UTF_8)
            @lexer.next
            return true
          end
          value = +""
          field.default_value = value
          case field.type
          when :TYPE_INT32, :TYPE_INT64, :TYPE_SINT32, :TYPE_SINT64, :TYPE_SFIXED32, :TYPE_SFIXED64
            max = %i[TYPE_INT32 TYPE_SINT32 TYPE_SFIXED32].include?(field.type) ? INT32_MAX : INT64_MAX
            if try_consume("-")
              value << "-"
              max += 1
            end
            n = consume_integer64(max, "Expected integer for field default value.")
            return false if n.nil?
            value << n.to_s
          when :TYPE_UINT32, :TYPE_UINT64, :TYPE_FIXED32, :TYPE_FIXED64
            max = %i[TYPE_UINT32 TYPE_FIXED32].include?(field.type) ? UINT32_MAX : UINT64_MAX
            record_error("Unsigned field can't have negative default value.") if try_consume("-")
            n = consume_integer64(max, "Expected integer for field default value.")
            return false if n.nil?
            value << n.to_s
          when :TYPE_FLOAT, :TYPE_DOUBLE
            value << "-" if try_consume("-")
            n = consume_number("Expected number.")
            return false if n.nil?
            value << Compiler.simple_dtoa(n)
          when :TYPE_BOOL
            if try_consume("true")
              value.replace("true")
            elsif try_consume("false")
              value.replace("false")
            else
              record_error("Expected \"true\" or \"false\".")
              return false
            end
          when :TYPE_STRING
            s = consume_string("Expected string for field default value.")
            return false if s.nil?
            value.replace(s.force_encoding(Encoding::UTF_8))
          when :TYPE_BYTES
            s = consume_string("Expected string.")
            return false if s.nil?
            value.replace(Compiler.c_escape(s))
          when :TYPE_ENUM
            s = consume_identifier("Expected enum identifier for field default value.")
            return false if s.nil?
            value.replace(s)
          when :TYPE_MESSAGE, :TYPE_GROUP
            record_error("Messages can't have default values.")
            return false
          end
        end
        true
      end

      def parse_json_name(field, field_location)
        if field.json_name
          record_error("Already set option \"json_name\".")
          field.json_name = nil
        end
        scoped(field_location.child(FIELD_JSON_NAME)) do |location|
          location.record_legacy(field, :option_name)
          return false unless consume("json_name")
          return false unless consume("=")
          scoped(location.child) do |value_location|
            value_location.record_legacy(field, :option_value)
            s = consume_string("Expected string for JSON name.")
            return false if s.nil?
            field.json_name = s.force_encoding(Encoding::UTF_8)
          end
        end
        true
      end

      def parse_option_name_part(option, part_location)
        part = [+"", false]
        option.name << part
        if looking_at?("(")
          return false unless consume("(")
          scoped(part_location.child(NAME_PART)) do
            if looking_at_type?(:identifier)
              id = consume_identifier("Expected identifier.")
              return false if id.nil?
              part[0] << id
            end
            while looking_at?(".")
              return false unless consume(".")
              part[0] << "."
              id = consume_identifier("Expected identifier.")
              return false if id.nil?
              part[0] << id
            end
          end
          return false unless consume(")")
          part[1] = true
        else
          scoped(part_location.child(NAME_PART)) do
            id = consume_identifier("Expected identifier.")
            return false if id.nil?
            part[0] << id
          end
        end
        true
      end

      def parse_uninterpreted_block
        unless looking_at?("{")
          record_error("Expected \"{\".")
          return nil
        end
        value = +""
        depth = 1
        @lexer.report_whitespace = true
        @lexer.report_newlines = true
        begin
          @lexer.next
          until at_end?
            if looking_at?("{")
              depth += 1
            elsif looking_at?("}")
              depth -= 1
              break if depth == 0
            end
            cur = @lexer.current
            prev = @lexer.previous
            prev_end_line = (prev.type == :newline) ? prev.line + 1 : prev.line
            if cur.line > prev_end_line
              value << ("\n" * (cur.line - prev_end_line))
              value << (" " * cur.column)
            elsif cur.line == prev_end_line && cur.column > prev.end_column
              value << (" " * (cur.column - prev.end_column))
            end
            value << cur.text
            @lexer.next
          end
        ensure
          @lexer.report_whitespace = false
          @lexer.report_newlines = false
        end
        if depth == 0
          @lexer.next
          value.force_encoding(Encoding::UTF_8)
        else
          record_error("Unexpected end of stream while parsing aggregate value.")
          nil
        end
      end

      # - `holder`: the element whose options this sets
      # - `style`: :statement (`option x = y;`) or :assignment (`[x = y]`)
      #: (AST::Node holder, untyped options_location, Symbol style) -> untyped
      def parse_option(holder, options_location, style)
        options = (holder.options ||= AST::Options.new)
        scoped(options_location.child(UNINTERPRETED_OPTION, options.uninterpreted.size)) do |location|
          if style == :statement
            return false unless consume("option")
          end
          option = AST::Option.new
          options.uninterpreted << option

          scoped(location.child(OPTION_NAME)) do |name_location|
            name_location.record_legacy(option, :option_name)
            scoped(name_location.child(option.name.size)) do |part_location|
              return false unless parse_option_name_part(option, part_location)
            end
            while looking_at?(".")
              return false unless consume(".")
              scoped(name_location.child(option.name.size)) do |part_location|
                return false unless parse_option_name_part(option, part_location)
              end
            end
          end

          return false unless consume("=")

          scoped(location.child) do |value_location|
            value_location.record_legacy(option, :option_value)
            negative = try_consume("-")
            type = @lexer.current.type
            case type
            when :end
              record_error("Unexpected end of stream while parsing option value.")
              return false
            when :identifier
              value_location.add_path(OPTION_IDENTIFIER_VALUE)
              id = consume_identifier("Expected identifier.")
              return false if id.nil?
              if negative
                if id == "inf"
                  option.value_kind = :double_value
                  option.value = -Float::INFINITY
                elsif id == "nan"
                  option.value_kind = :double_value
                  option.value = Float::NAN
                else
                  record_error("Identifier after '-' symbol must be inf or nan.")
                  return false
                end
              else
                option.value_kind = :identifier_value
                option.value = id
              end
            when :integer, :float
              int = if type == :integer
                try_consume_integer64(negative ? INT64_MAX + 1 : UINT64_MAX)
              end
              if int
                if negative
                  value_location.add_path(OPTION_NEGATIVE_INT_VALUE)
                  option.value_kind = :negative_int_value
                  option.value = -int
                else
                  value_location.add_path(OPTION_POSITIVE_INT_VALUE)
                  option.value_kind = :positive_int_value
                  option.value = int
                end
              else
                value_location.add_path(OPTION_DOUBLE_VALUE)
                n = consume_number("Expected number.")
                return false if n.nil?
                option.value_kind = :double_value
                option.value = negative ? -n : n
              end
            when :string
              value_location.add_path(OPTION_STRING_VALUE)
              if negative
                record_error("Invalid '-' symbol before string.")
                return false
              end
              s = consume_string("Expected string.")
              return false if s.nil?
              option.value_kind = :string_value
              option.value = s
            else
              unless looking_at?("{")
                record_error("Expected option value.")
                return false
              end
              value_location.add_path(OPTION_AGGREGATE_VALUE)
              block = parse_uninterpreted_block
              return false if block.nil?
              option.value_kind = :aggregate_value
              option.value = block
            end
          end

          if style == :statement
            return false unless consume_end_of_declaration(";", location)
          end
        end
        true
      end

      def parse_extensions(message, extensions_location)
        return false unless consume("extensions")
        old_size = message.extension_range.size
        loop do
          range = AST::Range.new
          ok = scoped(extensions_location.child(message.extension_range.size)) do |location|
            message.extension_range << range
            location.record_legacy(range, :number)
            start_token = nil
            start = nil
            scoped(location.child(RANGE_START)) do
              start_token = @lexer.current.dup
              start = consume_integer("Expected field number range.")
              return false if start.nil?
              if start == INT32_MAX
                record_error("Field number out of bounds.")
                return false
              end
            end
            last = nil
            if try_consume("to")
              scoped(location.child(RANGE_END)) do
                if try_consume("max")
                  last = MAX_RANGE_SENTINEL - 1
                else
                  last = consume_integer("Expected integer.")
                  return false if last.nil?
                  if last == INT32_MAX
                    record_error("Field number out of bounds.")
                    return false
                  end
                end
              end
            else
              scoped(location.child(RANGE_END)) do |end_location|
                end_location.start_at(start_token)
                end_location.end_at(start_token)
                last = start
              end
            end
            range.start = start
            range.end = last + 1
            true
          end
          return false unless ok
          break unless try_consume(",")
        end

        if looking_at?("[")
          range_number_index = extensions_location.path_size
          info = []
          first = message.extension_range[old_size]
          first.options ||= AST::Options.new
          index_location = extensions_location.child(0, target: info)
          begin
            scoped(index_location.child(RANGE_OPTIONS)) do |location|
              return false unless consume("[")
              loop do
                return false unless parse_option(first, location, :assignment)
                break unless try_consume(",")
              end
              return false unless consume("]")
            end
          ensure
            index_location.finish
          end
          ((old_size + 1)...message.extension_range.size).each do |i|
            message.extension_range[i].options = first.options.copy
          end
          (old_size...message.extension_range.size).each do |i|
            info.each do |loc|
              next if loc.path.size == range_number_index + 1
              path = loc.path.dup
              path[range_number_index] = i
              @locations << loc.dup_with_path(path)
            end
          end
        end

        consume_end_of_declaration(";", extensions_location)
      end

      def parse_message_reserved(message, message_location)
        parse_reserved(message, message_location, MESSAGE_RESERVED_NAME, MESSAGE_RESERVED_RANGE, enum: false)
      end

      def parse_reserved(holder, parent_location, name_number, range_number, enum:)
        start_token = @lexer.current.dup
        return false unless consume("reserved")
        if looking_at_type?(:string)
          if @syntax_identifier == "editions"
            record_error("Reserved names must be identifiers in editions, not string literals.")
            return false
          end
          scoped(parent_location.child(name_number)) do |location|
            location.start_at(start_token)
            parse_reserved_names(holder, location, enum ? "Expected enum value string literal." : "Expected field name string literal.")
          end
        elsif looking_at_type?(:identifier)
          if @syntax_identifier != "editions"
            record_error("Reserved names must be string literals. (Only editions supports identifiers.)")
            return false
          end
          scoped(parent_location.child(name_number)) do |location|
            location.start_at(start_token)
            parse_reserved_identifiers(holder, location, enum ? "Expected enum value identifier." : "Expected field name identifier.")
          end
        else
          scoped(parent_location.child(range_number)) do |location|
            location.start_at(start_token)
            enum ? parse_enum_reserved_numbers(holder, location) : parse_reserved_numbers(holder, location)
          end
        end
      end

      def parse_reserved_names(holder, parent_location, error)
        loop do
          scoped(parent_location.child(holder.reserved_name.size)) do
            line = @lexer.current.line
            column = @lexer.current.column
            name = consume_string(error)
            holder.reserved_name << (name || "".b).dup.force_encoding(Encoding::UTF_8)
            return false if name.nil?
            name = holder.reserved_name.last
            unless Lexer.identifier?(name)
              record_warning_at(line, column, "Reserved name \"#{name}\" is not a valid identifier.")
            end
          end
          break unless try_consume(",")
        end
        consume_end_of_declaration(";", parent_location)
      end

      def parse_reserved_identifiers(holder, parent_location, error)
        loop do
          scoped(parent_location.child(holder.reserved_name.size)) do
            name = consume_identifier(error)
            holder.reserved_name << (name || +"")
            return false if name.nil?
          end
          break unless try_consume(",")
        end
        consume_end_of_declaration(";", parent_location)
      end

      def parse_reserved_numbers(message, parent_location)
        first = true
        loop do
          range = AST::Range.new
          ok = scoped(parent_location.child(message.reserved_range.size)) do |location|
            message.reserved_range << range
            location.record_legacy(range, :number)
            start_token = nil
            start = nil
            scoped(location.child(RANGE_START)) do
              start_token = @lexer.current.dup
              start = consume_integer(first ? "Expected field name or number range." : "Expected field number range.")
              return false if start.nil?
              if start == INT32_MAX
                record_error("Field number out of bounds.")
                return false
              end
            end
            last = nil
            if try_consume("to")
              scoped(location.child(RANGE_END)) do
                if try_consume("max")
                  last = MAX_RANGE_SENTINEL - 1
                else
                  last = consume_integer("Expected integer.")
                  return false if last.nil?
                  if last == INT32_MAX
                    record_error("Field number out of bounds.")
                    return false
                  end
                end
              end
            else
              scoped(location.child(RANGE_END)) do |end_location|
                end_location.start_at(start_token)
                end_location.end_at(start_token)
                last = start
              end
            end
            range.start = start
            range.end = last + 1
            true
          end
          return false unless ok
          first = false
          break unless try_consume(",")
        end
        consume_end_of_declaration(";", parent_location)
      end

      def parse_enum_reserved_numbers(enum, parent_location)
        first = true
        loop do
          range = AST::Range.new
          ok = scoped(parent_location.child(enum.reserved_range.size)) do |location|
            enum.reserved_range << range
            location.record_legacy(range, :number)
            start_token = nil
            start = nil
            scoped(location.child(RANGE_START)) do
              start_token = @lexer.current.dup
              start = consume_signed_integer(first ? "Expected enum value or number range." : "Expected enum number range.")
              return false if start.nil?
            end
            last = nil
            if try_consume("to")
              scoped(location.child(RANGE_END)) do
                if try_consume("max")
                  last = INT32_MAX
                else
                  last = consume_signed_integer("Expected integer.")
                  return false if last.nil?
                end
              end
            else
              scoped(location.child(RANGE_END)) do |end_location|
                end_location.start_at(start_token)
                end_location.end_at(start_token)
                last = start
              end
            end
            range.start = start
            range.end = last
            true
          end
          return false unless ok
          first = false
          break unless try_consume(",")
        end
        consume_end_of_declaration(";", parent_location)
      end

      def parse_extend(extensions, messages, parent_location, nested_type_number, extend_location)
        return false unless consume("extend")
        extendee_start = @lexer.current.dup
        extendee = parse_user_defined_type
        return false if extendee.nil?
        extendee_end = @lexer.previous.dup
        return false unless consume_end_of_declaration("{", extend_location)
        is_first = true
        loop do
          if at_end?
            record_error("Reached end of input in extend definition (missing '}').")
            return false
          end
          field = AST::Field.new
          scoped(extend_location.child(extensions.size)) do |location|
            extensions << field
            scoped(location.child(FIELD_EXTENDEE)) do |extendee_location|
              extendee_location.start_at(extendee_start)
              extendee_location.end_at(extendee_end)
              if is_first
                extendee_location.record_legacy(field, :extendee)
                is_first = false
              end
            end
            field.extendee = extendee
            skip_statement unless parse_message_field(field, messages, parent_location, nested_type_number, location)
          end
          break if try_consume_end_of_declaration("}", nil)
        end
        true
      end

      def parse_oneof(oneof, message, index, oneof_location, message_location)
        return false unless consume("oneof")
        scoped(oneof_location.child(ONEOF_NAME)) do
          name = consume_identifier("Expected oneof name.")
          return false if name.nil?
          oneof.name = name
        end
        return false unless consume_end_of_declaration("{", oneof_location)
        loop do
          if at_end?
            record_error("Reached end of input in oneof definition (missing '}').")
            return false
          end
          if looking_at?("option")
            ok = scoped(oneof_location.child(ONEOF_OPTIONS)) do |location|
              parse_option(oneof, location, :statement)
            end
            return false unless ok
          else
            if looking_at?("required") || looking_at?("optional") || looking_at?("repeated")
              record_error("Fields in oneofs must not have labels (required / optional / repeated).")
              @lexer.next
            end
            field = AST::Field.new
            scoped(message_location.child(MESSAGE_FIELD, message.field.size)) do |location|
              message.field << field
              field.label = :LABEL_OPTIONAL
              field.oneof_index = index
              unless parse_message_field_no_label(field, message.nested_type, message_location, MESSAGE_NESTED_TYPE, location)
                skip_statement
              end
            end
          end
          break if try_consume_end_of_declaration("}", nil)
        end
        true
      end

      def parse_enum_definition(enum, visibility, enum_location)
        return false unless consume("enum")
        scoped(enum_location.child(ENUM_NAME)) do |location|
          location.record_legacy(enum, :name)
          name = consume_identifier("Expected enum name.")
          return false if name.nil?
          enum.name = name
        end
        return false unless parse_enum_block(enum, enum_location)
        return false unless validate_enum(enum)
        enum.visibility = visibility if visibility
        true
      end

      def parse_enum_block(enum, enum_location)
        return false unless consume_end_of_declaration("{", enum_location)
        until try_consume_end_of_declaration("}", nil)
          if at_end?
            record_error("Reached end of input in enum definition (missing '}').")
            return false
          end
          skip_statement unless parse_enum_statement(enum, enum_location)
        end
        true
      end

      def parse_enum_statement(enum, enum_location)
        if try_consume_end_of_declaration(";", nil)
          true
        elsif looking_at?("option")
          scoped(enum_location.child(ENUM_OPTIONS)) { |location| parse_option(enum, location, :statement) }
        elsif looking_at?("reserved")
          parse_reserved(enum, enum_location, ENUM_RESERVED_NAME, ENUM_RESERVED_RANGE, enum: true)
        else
          value = AST::EnumValue.new
          scoped(enum_location.child(ENUM_VALUE, enum.value.size)) do |location|
            enum.value << value
            parse_enum_constant(value, location)
          end
        end
      end

      def parse_enum_constant(value, value_location)
        scoped(value_location.child(ENUM_VALUE_NAME)) do |location|
          location.record_legacy(value, :name)
          name = consume_identifier("Expected enum constant name.")
          return false if name.nil?
          value.name = name
        end
        return false unless consume("=", "Missing numeric value for enum constant.")
        scoped(value_location.child(ENUM_VALUE_NUMBER)) do |location|
          location.record_legacy(value, :number)
          number = consume_signed_integer("Expected integer.")
          return false if number.nil?
          value.number = number
        end
        if looking_at?("[")
          ok = scoped(value_location.child(ENUM_VALUE_OPTIONS)) do |location|
            return false unless consume("[")
            loop do
              return false unless parse_option(value, location, :assignment)
              break unless try_consume(",")
            end
            consume("]")
          end
          return false unless ok
        end
        consume_end_of_declaration(";", value_location)
      end

      def parse_service_definition(service, service_location)
        return false unless consume("service")
        scoped(service_location.child(SERVICE_NAME)) do |location|
          location.record_legacy(service, :name)
          name = consume_identifier("Expected service name.")
          return false if name.nil?
          service.name = name
        end
        return false unless consume_end_of_declaration("{", service_location)
        until try_consume_end_of_declaration("}", nil)
          if at_end?
            record_error("Reached end of input in service definition (missing '}').")
            return false
          end
          skip_statement unless parse_service_statement(service, service_location)
        end
        true
      end

      def parse_service_statement(service, service_location)
        if try_consume_end_of_declaration(";", nil)
          true
        elsif looking_at?("option")
          scoped(service_location.child(SERVICE_OPTIONS)) { |location| parse_option(service, location, :statement) }
        else
          method = AST::Method.new
          scoped(service_location.child(SERVICE_METHOD, service.rpcs.size)) do |location|
            service.rpcs << method
            parse_service_method(method, location)
          end
        end
      end

      def parse_service_method(method, method_location)
        return false unless consume("rpc")
        scoped(method_location.child(METHOD_NAME)) do |location|
          location.record_legacy(method, :name)
          name = consume_identifier("Expected method name.")
          return false if name.nil?
          method.name = name
        end
        return false unless consume("(")
        if looking_at?("stream")
          scoped(method_location.child(METHOD_CLIENT_STREAMING)) do |location|
            location.record_legacy(method, :other)
            method.client_streaming = true
            return false unless consume("stream")
          end
        end
        scoped(method_location.child(METHOD_INPUT_TYPE)) do |location|
          location.record_legacy(method, :input_type)
          type = parse_user_defined_type
          return false if type.nil?
          method.input_type = type
        end
        return false unless consume(")")
        return false unless consume("returns")
        return false unless consume("(")
        if looking_at?("stream")
          scoped(method_location.child(METHOD_SERVER_STREAMING)) do |location|
            location.record_legacy(method, :other)
            return false unless consume("stream")
            method.server_streaming = true
          end
        end
        scoped(method_location.child(METHOD_OUTPUT_TYPE)) do |location|
          location.record_legacy(method, :output_type)
          type = parse_user_defined_type
          return false if type.nil?
          method.output_type = type
        end
        return false unless consume(")")
        if looking_at?("{")
          parse_method_options(method, method_location)
        else
          consume_end_of_declaration(";", method_location)
        end
      end

      def parse_method_options(method, parent_location)
        consume_end_of_declaration("{", parent_location)
        until try_consume_end_of_declaration("}", nil)
          if at_end?
            record_error("Reached end of input in method options (missing '}').")
            return false
          end
          next if try_consume_end_of_declaration(";", nil)
          ok = scoped(parent_location.child(METHOD_OPTIONS)) do |location|
            parse_option(method, location, :statement)
          end
          skip_statement unless ok
        end
        true
      end

      #: (untyped field_location) -> Symbol?
      def parse_label(field_location)
        return nil unless looking_at?("optional") || looking_at?("repeated") || looking_at?("required")
        if looking_at?("optional") && @syntax_identifier == "editions"
          record_error("Label \"optional\" is not supported in editions. By default, all singular fields have " \
            "presence unless features.field_presence is set.")
        end
        if looking_at?("required") && @syntax_identifier == "editions"
          record_error("Label \"required\" is not supported in editions, use features.field_presence = LEGACY_REQUIRED.")
        end
        scoped(field_location.child(FIELD_LABEL)) do
          if try_consume("optional")
            :LABEL_OPTIONAL
          elsif try_consume("repeated")
            :LABEL_REPEATED
          else
            consume("required")
            :LABEL_REQUIRED
          end
        end
      end

      def fixed_wire_for_int_types?
        @syntax_identifier == "editions" && @edition == :EDITION_UNSTABLE
      end

      # Returns the type, or "" and a type name.
      #: () -> [Symbol, String]?
      def parse_type
        table = fixed_wire_for_int_types? ? UNSTABLE_TYPES : TYPES
        text = @lexer.current.text
        if (type = table[text])
          if @syntax_identifier == "editions" && type == :TYPE_GROUP
            record_error("Group syntax is no longer supported in editions. To get group behavior you can specify " \
              "features.message_encoding = DELIMITED on a message field.")
          end
          @lexer.next
          [type, ""]
        elsif fixed_wire_for_int_types? && (replacement = UNSTABLE_REPLACEMENTS[text])
          record_error("Type '#{text}' is obsolete in unstable editions, use '#{replacement}' instead.")
          @lexer.next
          [:TYPE_INT32, ""]
        else
          name = parse_user_defined_type
          name && [:TYPE_INT32, name]
        end
      end

      #: () -> String?
      def parse_user_defined_type
        if TYPES.key?(@lexer.current.text)
          record_error("Expected message type.")
          name = @lexer.current.text.dup
          @lexer.next
          return name
        end
        name = +""
        name << "." if try_consume(".")
        id = consume_identifier("Expected type name.")
        return nil if id.nil?
        name << id
        while try_consume(".")
          name << "."
          id = consume_identifier("Expected identifier.")
          return nil if id.nil?
          name << id
        end
        name
      end

      def parse_package(file, root)
        if file.package
          record_error("Multiple package definitions.")
          file.package = nil
        end
        scoped(root.child(FILE_PACKAGE)) do |location|
          location.record_legacy(file, :name)
          return false unless consume("package")
          package = +""
          file.package = package
          loop do
            id = consume_identifier("Expected identifier.")
            return false if id.nil?
            package << id
            break unless try_consume(".")
            package << "."
          end
          consume_end_of_declaration(";", location)
        end
      end

      def parse_import(file, root)
        import_start = @lexer.current.dup
        return false unless consume("import")
        if looking_at?("option")
          record_error("option import is not supported before edition 2024.") if edition_number < 1001
          return scoped(root.child(FILE_OPTION_DEPENDENCY, file.option_dependency.size)) do |location|
            location.start_at(import_start)
            return false unless consume("option")
            name = consume_string("Expected a string naming the file to import.")
            return false if name.nil?
            name = name.force_encoding(Encoding::UTF_8)
            file.option_dependency << name
            file.import_positions[name] = location.start
            consume_end_of_declaration(";", location)
          end
        end
        scoped(root.child(FILE_DEPENDENCY, file.dependency.size)) do |location|
          location.start_at(import_start)
          unless file.option_dependency.empty?
            record_error("imports should precede any option imports to ensure proto files can roundtrip.")
          end
          if looking_at?("public")
            scoped(root.child(FILE_PUBLIC_DEPENDENCY, file.public_dependency.size)) do
              return false unless consume("public")
              file.public_dependency << file.dependency.size
            end
          elsif looking_at?("weak")
            if edition_number >= 1001
              record_error("weak import is not supported in edition 2024 and above. Consider using option import instead.")
            end
            scoped(root.child(FILE_WEAK_DEPENDENCY, file.weak_dependency.size)) do |weak_location|
              file.import_positions["weak"] = weak_location.start
              return false unless consume("weak")
              file.weak_dependency << file.dependency.size
            end
          end
          name = consume_string("Expected a string naming the file to import.")
          return false if name.nil?
          name = name.force_encoding(Encoding::UTF_8)
          file.dependency << name
          file.import_positions[name] = location.start
          consume_end_of_declaration(";", location)
        end
      end

      # Returns success and the visibility, if any.
      #: (untyped file) -> [bool, Symbol?]
      def parse_visibility(file)
        return [true, nil] if Schema::Features::EDITIONS.fetch(file.edition, 0) <= 1000
        visibility = if try_consume("export")
          :VISIBILITY_EXPORT
        elsif try_consume("local")
          :VISIBILITY_LOCAL
        end
        if visibility && !looking_at?("message") && !looking_at?("enum")
          record_error("'local' and 'export' visibility modifiers are valid only on 'message' and 'enum'")
          return [false, nil]
        end
        [true, visibility]
      end
    end
  end
end
