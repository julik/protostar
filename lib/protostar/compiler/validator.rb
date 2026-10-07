# frozen_string_literal: true

module Protostar
  class Compiler
    # The checks protoc runs once a file's options are interpreted:
    # DescriptorBuilder's ValidateOptions phase, map entry conflict hints,
    # unused imports, naming style, proto limits and symbol visibility, and
    # feature lifetimes, in that order. Checks read the built {Schema::File}
    # and report against the AST's recorded positions.
    #
    # @api private
    class Validator
      INT32_MAX = 2**31 - 1
      MAX_FIELD_NUMBER = 536_870_911
      OPTIONS_EXTENDEES = %w[FileOptions MessageOptions FieldOptions EnumOptions EnumValueOptions ServiceOptions
        MethodOptions OneofOptions ExtensionRangeOptions].flat_map { |n| ["google.protobuf.#{n}", "proto2.#{n}"] }.freeze
      DESCRIPTOR_OPTIONS = OPTIONS_EXTENDEES.select { |n| n.start_with?("google.") }.freeze
      INT64_TYPES = %i[int64 uint64 sint64 fixed64 sfixed64].freeze
      NON_MESSAGE_TYPES = %w[double float int64 uint64 int32 fixed32 fixed64 bool string bytes uint32 enum sfixed32
        sfixed64 sint32 sint64].freeze
      NAMING_OPT_OUT = " (features.enforce_naming_style = STYLE_LEGACY can be used to opt out of this check)"
      COLLISION_OPT_OUT = " (features.enforce_naming_style = STYLE2024 can be used to opt out of this check)"
      LIMITS_OPT_OUT = " (features.enforce_proto_limits = LEGACY_NO_EXPLICIT_LIMITS can be used to opt out of this check)"
      LIMIT_FIELDS_PER_MESSAGE = 65_535
      LIMIT_ONEOFS_PER_MESSAGE = 255
      LIMIT_FIELDS_PER_ONEOF = 255
      LIMIT_VALUES_PER_ENUM = 65_535
      TARGET_TYPES = {
        file: [:TARGET_TYPE_FILE, "file"], extension_range: [:TARGET_TYPE_EXTENSION_RANGE, "extension range"],
        message: [:TARGET_TYPE_MESSAGE, "message"], field: [:TARGET_TYPE_FIELD, "field"],
        oneof: [:TARGET_TYPE_ONEOF, "oneof"], enum: [:TARGET_TYPE_ENUM, "enum"],
        enum_value: [:TARGET_TYPE_ENUM_ENTRY, "enum entry"], service: [:TARGET_TYPE_SERVICE, "service"],
        method: [:TARGET_TYPE_METHOD, "method"]
      }.freeze

      def initialize(linker)
        @linker = linker
        @file = linker.file
        @ast = linker.ast
        @cli = linker.protoc_cli?
      end

      def validate
        validate_options if @file && !errors?
        @ast.message_type.each { |m| detect_map_conflicts(m) } if errors?
        return if errors?
        unused_imports
        each_element { |node, kind| naming_style(node, kind) } if @cli
        each_element { |node, kind| proto_limits(node, kind) } if @cli
        symbol_visibility if @cli
        feature_lifetimes unless errors?
      end

      # The command-line interface's checks over the files it was asked to
      # compile, once all of them are built
      # @param linkers [Array<Linker>]
      # @param run [Run]
      def self.cli_checks(linkers, run)
        linkers.each do |linker|
          file = linker.file
          options = file.options
          if options.cc_generic_services? || options.java_generic_services? || options.py_generic_services?
            run.report(file.name, nil, "Generic services (cc_generic_services, java_generic_services, and " \
              "py_generic_services) are deprecated in favor of using plugins that generate code specific to your " \
              "particular RPC system. Additional code generator options may be required to enable generic services " \
              "and total removal of these options is planned in future breaking releases.", :warning)
          end
          linker.each_element do |node, kind|
            next unless kind == :field
            next unless node.number.between?(19_000, 19_999)
            run.report(file.name, nil, "Field numbers 19000 through 19999 are reserved for the protocol buffer " \
              "library implementation.")
          end
        end
        linkers.each do |linker|
          validator = new(linker)
          linker.each_element { |node, kind| validator.target_constraints(node, kind, run) }
        end
        return if run.failed?
        linkers.each do |linker|
          file = linker.file
          next unless file.syntax == :editions
          next if skip_edition_check?(file.name)
          next unless Schema::Features::EDITIONS.fetch(file.edition) > Schema::Features::EDITIONS[:EDITION_2026]
          run.report(file.name, nil, "is a file using edition #{file.edition.to_s.delete_prefix("EDITION_")}, which " \
            "is later than the protoc maximum supported edition 2026.")
          break
        end
      end

      def self.skip_edition_check?(name)
        name.start_with?("google/protobuf/", "upb/", "com/google/protobuf/", "conformance/test_protos/",
          "test_messages_edition_unstable")
      end

      # Every option set on the element must allow the element's target type
      def target_constraints(node, kind, run)
        options = schema_options(node, kind)
        return if options.nil? || options.empty?
        type = options_message(kind)
        return unless type
        target, label = TARGET_TYPES.fetch(kind)
        check_targets(options, type, target, label, run)
      end

      private

      def errors?
        @linker.errors?
      end

      def error(node, location, message, related: [])
        @linker.error(node, location, message, related: related)
      end

      def warning(node, location, message, related: [])
        @linker.warning(node, location, message, related: related)
      end

      def each_element(&block)
        @linker.each_element(&block)
      end

      def check_targets(value, type, target, label, run)
        value.fields.each do |name, v|
          field = type.fields_by_name[name.to_s]
          check_target(field, v, target, label, run) if field
        end
        value.extensions.each { |field, v| check_target(field, v, target, label, run) }
      end

      def check_target(field, value, target, label, run)
        targets = field.options.targets
        unless targets.empty? || targets.include?(target)
          run.report(@ast.name, nil, "Option #{field.full_name} cannot be set on an entity of type `#{label}`.")
        end
        return unless field.type == :message || field.type == :group
        Array(field.repeated? ? value : [value]).each do |v|
          check_targets(v, field.message_type, target, label, run) if v.is_a?(Schema::MessageValue)
        end
      end

      # A built extension by full name: this file's or the pool's
      def extension_field(name)
        found = @file.find_symbol(name) || @linker.pool.find_symbol(name)
        found if found.is_a?(Schema::Field) && found.extension?
      end

      # The options message an element's options are read with
      def options_message(kind)
        name = Linker::OPTIONS_TYPES.fetch(kind)
        @file.find_message(name) || @linker.interpreter&.options_type(name)
      end

      # The Schema descriptor for an AST node
      def schema_of(node, _kind)
        @linker.descriptor_of(node)
      end

      def schema_options(node, kind)
        return nil unless node.options
        schema_of(node, kind).options
      end

      def validate_options
        each_element do |node, kind|
          case kind
          when :file then validate_file
          when :message then validate_message(node, schema_of(node, kind))
          when :field then validate_field(node, schema_of(node, kind))
          when :enum then validate_enum(node, schema_of(node, kind))
          when :enum_value then validate_enum_value(node, schema_of(node, kind))
          when :service then validate_service(node)
          end
        end
      end

      def lite?(file)
        file && file.options.optimize_for == :LITE_RUNTIME
      end

      def validate_file
        unless @linker.legacy?
          if @file.features.field_presence == :LEGACY_REQUIRED
            error(@ast, :editions, "Required presence can't be specified by default.")
          end
          if @file.options.java_string_check_utf8?
            error(@ast, :editions, "File option java_string_check_utf8 is not allowed under editions. Use the " \
              "(pb.java).utf8_validation feature to control this behavior.")
          end
        end
        unless lite?(@file)
          dep = @file.dependency_files.find { |d| lite?(d) }
          if dep
            @linker.import_error(dep.name, "Files that do not use optimize_for = LITE_RUNTIME cannot import files " \
              "which do use this option.  This file is not lite, but it imports \"#{dep.name}\" which is.")
          end
        end
        validate_proto3 if @linker.edition == :EDITION_PROTO3
        edition = @linker.edition_number
        if edition < 1001 && !@ast.option_dependency.empty?
          @linker.import_error("option", "option imports are not supported before edition 2024.")
        end
        if edition >= 1001 && !@ast.weak_dependency.empty?
          @linker.import_error("weak", "weak imports are not allowed under edition 2024 and beyond.")
        end
      end

      def validate_proto3
        @ast.extension.each { |f| validate_proto3_field(f) }
        @ast.message_type.each { |m| validate_proto3_message(m) }
      end

      def validate_proto3_message(message)
        message.nested_type.each { |m| validate_proto3_message(m) }
        message.field.each { |f| validate_proto3_field(f) }
        message.extension.each { |f| validate_proto3_field(f) }
        unless message.extension_range.empty?
          error(message.extension_range[0], :number, "Extension ranges are not allowed in proto3.")
        end
        if @file.find_message(message.full_name).message_set_wire_format?
          error(message, :name, "MessageSet is not supported in proto3.")
        end
      end

      def validate_proto3_field(node)
        field = @file.find_symbol(node.full_name)
        if field.extension? && !OPTIONS_EXTENDEES.include?(field.extendee.full_name)
          error(node, :extendee, "Extensions in proto3 are only allowed for defining options.")
        end
        error(node, :type, "Required fields are not allowed in proto3.") if field.required?
        error(node, :default_value, "Explicit default values are not allowed in proto3.") if node.default_value
        if field.type == :enum && field.enum_type.closed?
          holder = field.extension? ? field.extendee : field.containing_message
          error(node, :type, "Enum type \"#{field.enum_type.full_name}\" is not an open enum, but is used in " \
            "\"#{holder.full_name}\" which is a proto3 message type.")
        end
        error(node, :type, "Groups are not supported in proto3 syntax.") if field.type == :group
      end

      def validate_message(node, message)
        unless message.options.deprecated_legacy_json_field_conflicts?
          json_name_uniqueness(node, message, false)
          json_name_uniqueness(node, message, true)
        end
        extension_range_options(node, message)
      end

      def json_name_uniqueness(node, message, use_custom)
        seen = {}
        node.field.each do |field|
          default = Schema.json_name(field.name)
          custom = use_custom && field.json_name && field.json_name != default
          name = custom ? field.json_name : default
          if custom && name.start_with?("[") && name.end_with?("]")
            error(field, :name, "The custom JSON name of field \"#{field.name}\" (\"#{name}\") is invalid: JSON " \
              "names may not start with '[' and end with ']'.")
            next
          end
          unless seen.key?(name)
            seen[name] = [field, name, custom]
            next
          end
          match, match_name, match_custom = seen[name]
          next if use_custom && !custom && !match_custom
          suffix = (name != match_name) ? " (\"#{match_name}\")" : ""
          text = "The #{custom ? "custom" : "default"} JSON name of field \"#{field.name}\" (\"#{name}\") conflicts " \
            "with the #{match_custom ? "custom" : "default"} JSON name of field \"#{match.name}\"#{suffix}."
          related = [[match, :name, "`#{match.name}` has it too"]]
          if message.features.json_format == :LEGACY_BEST_EFFORT && (!custom || !match_custom)
            warning(field, :name, text, related: related)
          else
            error(field, :name, text, related: related)
          end
        end
      end

      def extension_range_options(node, message)
        max = message.message_set_wire_format? ? INT32_MAX : MAX_FIELD_NUMBER
        names = {}
        message.extension_range_descriptors.each_with_index do |range, i|
          if range.range.end + 1 > max + 1
            error(node, :number, "Extension numbers cannot be greater than #{max}.")
          end
          declarations = range.options.declaration
          next if declarations.empty?
          range_node = node.extension_range[i]
          if range.options.verification == :UNVERIFIED
            error(range_node, :extendee, "Cannot mark the extension range as UNVERIFIED when it has extension(s) " \
              "declared.")
            break
          end
          validate_declarations(range_node, range, declarations, names)
        end
      end

      def validate_declarations(node, range, declarations, names)
        numbers = {}
        declarations.each do |d|
          number = d[:number]
          unless range.range.cover?(number)
            error(node, :number, "Extension declaration number #{number} is not in the extension range.")
          end
          if numbers[number]
            error(node, :number, "Extension declaration number #{number} is declared multiple times.")
          end
          numbers[number] = true
          if !d.key?(:full_name) || !d.key?(:type)
            if d.key?(:full_name) != d.key?(:type) || !d[:reserved]
              error(node, :extendee, "Extension declaration ##{number} should have both \"full_name\" and \"type\" set.")
            end
          else
            if names[d[:full_name]]
              error(node, :name, "Extension field name \"#{d[:full_name]}\" is declared multiple times.")
              break
            end
            names[d[:full_name]] = true
            if (problem = declaration_symbol_problem(d[:full_name]))
              error(node, :name, problem)
            end
            if !NON_MESSAGE_TYPES.include?(d[:type]) && (problem = declaration_symbol_problem(d[:type]))
              error(node, :name, problem)
            end
          end
        end
      end

      def declaration_symbol_problem(symbol)
        return "\"#{symbol}\" must have a leading dot to indicate the fully-qualified scope." unless symbol.start_with?(".")
        unless symbol[1..].match?(/\A[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*\z/)
          return "\"#{symbol}\" contains invalid identifiers."
        end
        nil
      end

      def validate_field(node, field)
        if @cli
          problem = feature_support_problem(field.options.feature_support, field.full_name)
          if problem.nil? && field.type == :enum
            field.enum_type.values.each do |value|
              problem = enum_value_support_problem(field.options.feature_support, value, field.full_name)
              break if problem
            end
          end
          error(node, :option_name, problem) if problem
        end
        field_features(node, field)
        options = field.options
        if @linker.edition_number >= 1001 && options.key?(:ctype)
          error(node, :type, "ctype option is not allowed under edition 2024 and beyond. Use the feature " \
            "string_type = VIEW|CORD|STRING|... instead.")
        end
        if options.lazy? || options.unverified_lazy?
          if field.type != :message
            error(node, :type, "[lazy = true] can only be specified for submessage fields.")
          end
          if options.unverified_lazy? && field.extension?
            error(node, :type, "Extensions cannot be marked as unverified_lazy.")
          end
        end
        if options.packed? && !field.packable?
          error(node, :type, "[packed = true] can only be specified for repeated primitive fields.")
        end
        holder = field.extension? ? field.extendee : field.containing_message
        if holder&.message_set_wire_format?
          if field.extension?
            if field.required? || field.repeated? || field.type != :message
              error(node, :type, "Extensions of MessageSets must be optional messages.")
            end
          else
            error(node, :name, "MessageSets cannot have fields, only extensions.")
          end
        end
        if lite?(@file) && field.extension? && !lite?(field.extendee.file)
          error(node, :extendee, "Extensions to non-lite types can only be declared in non-lite files.  Note that " \
            "you cannot extend a non-lite type to contain a lite type, but the reverse is allowed.")
        end
        if field.type == :group && field.message_type&.map_entry?
          error(node, :type, "Groups cannot be map entries. Use a regular message field with map<KeyType, " \
            "ValueType> syntax instead.")
        end
        validate_map(node, field) if field.type == :message && field.message_type.map_entry?
        jstype(node, field)
        if field.extension? && node.json_name && node.json_name != Schema.json_name(node.name)
          error(node, :option_name, "option json_name is not allowed on extension fields.")
        end
        if field.json_name.include?("\0")
          error(node, :option_name, "json_name cannot have embedded null characters.")
        end
        extension_declaration(node, field) if field.extension? && @cli
      end

      def field_features(node, field)
        return if @linker.edition_number < 1000
        if node.label == :LABEL_REQUIRED
          error(node, :name, "Required label is not allowed under editions.  Use the feature field_presence = " \
            "LEGACY_REQUIRED to control this behavior.")
        end
        if node.type == :TYPE_GROUP
          error(node, :name, "Group types are not allowed under editions.  Use the feature message_encoding = " \
            "DELIMITED to control this behavior.")
        end
        if field.options.key?(:packed)
          error(node, :name, "Field option packed is not allowed under editions.  Use the repeated_field_encoding " \
            "feature to control this behavior.")
        end
        if !field.repeated? && !field.presence?
          error(node, :name, "Implicit presence fields can't specify defaults.") if node.default_value
          if field.type == :enum && field.enum_type.closed?
            error(node, :name, "Implicit presence enum fields must always be open.")
          end
        end
        error(node, :name, "Extensions can't be required.") if field.extension? && field.required?
        return if !field.extension? && field.containing_message.map_entry?
        raw = field.options[:features] || Schema::MessageValue::EMPTY
        if raw.key?(:field_presence)
          if field.real_oneof || field.oneof
            error(node, :name, "Oneof fields can't specify field presence.")
          elsif field.repeated?
            error(node, :name, "Repeated fields can't specify field presence.")
          elsif field.extension? && raw[:field_presence] != :LEGACY_REQUIRED
            error(node, :name, "Extensions can't specify field presence.")
          elsif field.message_type && raw[:field_presence] == :IMPLICIT
            error(node, :name, "Message fields can't specify implicit presence.")
          end
        end
        if !field.repeated? && raw.key?(:repeated_field_encoding)
          error(node, :name, "Only repeated fields can specify repeated field encoding.")
        end
        string_map = field.map? && field.message_type.fields.any? { |f| f.type == :string }
        if field.type != :string && !string_map && raw.key?(:utf8_validation)
          error(node, :name, "Only string fields can specify utf8 validation.")
        end
        if !field.packable? && raw[:repeated_field_encoding] == :PACKED
          error(node, :name, "Only repeated primitive fields can specify PACKED repeated field encoding.")
        end
        message_like = (field.type == :message || field.type == :group) && !field.message_type.map_entry?
        if !message_like && raw.key?(:message_encoding)
          error(node, :name, "Only message fields can specify message encoding.")
        end
      end

      def validate_map(node, field)
        entry = field.message_type
        expected = camel_case(field.name) + "Entry"
        if !field.repeated? || entry.name != expected || !entry.containing_message.equal?(field.containing_message)
          text = "#{entry.full_name} is a synthetic MapEntry message type, which is not allowed to be used as a " \
            "field type."
          if (container = entry.containing_message)
            alternative = @linker.table.lookup(entry.name, container.full_name, types_only: true)
            if alternative && alternative.full_name != entry.full_name
              text += " Maybe you meant \".#{alternative.full_name}\"?"
            end
          end
          error(node, :type, text)
        end
        unless valid_map_entry?(node, entry)
          error(node, :type, "map_entry should not be set explicitly. Use map<KeyType, ValueType> instead.")
        end
      end

      def camel_case(name)
        out = +""
        upper = true
        name.each_char do |c|
          if c == "_"
            upper = true
          elsif upper
            out << c.upcase(:ascii)
            upper = false
          else
            out << c
          end
        end
        out
      end

      def valid_map_entry?(node, entry)
        return false unless entry.extensions.empty? && entry.extension_ranges.empty? && entry.nested_messages.empty? &&
          entry.nested_enums.empty? && entry.fields.size == 2
        key, value = entry.fields
        return false unless key.label == :optional && key.number == 1 && key.name == "key"
        return false unless value.label == :optional && value.number == 2 && value.name == "value"
        case key.type
        when :enum
          error(node, :type, "Key in map fields cannot be enum types.")
        when :float, :double, :message, :group, :bytes
          error(node, :type, "Key in map fields cannot be float/double, bytes or message types.")
        end
        if value.type == :enum && value.enum_type.values.first.number != 0
          error(node, :type, "Enum value in map must define 0 as the first value.")
        end
        true
      end

      def jstype(node, field)
        jstype = field.options.jstype
        return if jstype.nil? || jstype == :JS_NORMAL
        if INT64_TYPES.include?(field.type)
          return if jstype == :JS_STRING || jstype == :JS_NUMBER
          error(node, :type, "Illegal jstype for int64, uint64, sint64, fixed64 or sfixed64 field: #{jstype}")
        else
          error(node, :type, "jstype is only allowed on int64, uint64, sint64, fixed64 or sfixed64 fields.")
        end
      end

      def extension_declaration(node, field)
        extendee = field.extendee
        return if DESCRIPTOR_OPTIONS.include?(extendee.full_name)
        return if extendee.file.name == "google/protobuf/descriptor.proto"
        range = extendee.extension_range_descriptors.find { |r| r.range.cover?(field.number) }
        return if range.nil? || !range.options.declared?
        declarations = range.options.declaration
        declaration = declarations.find { |d| d[:number] == field.number }
        if declaration&.[](:reserved)
          error(node, :extendee, "Cannot use number #{field.number} for extension field #{field.full_name}, as it " \
            "is reserved in the extension declarations for message #{extendee.full_name}.")
        elsif declaration
          check_declaration(node, field, declaration)
        elsif !declarations.empty? || range.options.verification == :DECLARATION
          error(node, :extendee, "Missing extension declaration for field #{field.full_name} with number " \
            "#{field.number} in extendee message #{extendee.full_name}. An extension range must declare for all " \
            "extension fields if its verification state is DECLARATION or there's any declaration in the range " \
            "already. Otherwise, consider splitting up the range.")
        end
      end

      def check_declaration(node, field, declaration)
        extendee = field.extendee.full_name
        if (type = declaration[:type]) && !type.empty?
          actual = if field.message_type || field.enum_type
            ".#{(field.message_type || field.enum_type).full_name}"
          else
            field.type.to_s
          end
          expected = (NON_MESSAGE_TYPES.include?(type) || type.start_with?(".")) ? type : ".#{type}"
          if expected != actual
            error(node, :extendee, "\"#{extendee}\" extension field #{field.number} is expected to be type " \
              "\"#{expected}\", not \"#{actual}\".")
          end
        end
        if (name = declaration[:full_name]) && !name.empty? && name != ".#{field.full_name}"
          error(node, :extendee, "\"#{extendee}\" extension field #{field.number} is expected to have field name " \
            "\"#{name}\", not \".#{field.full_name}\".")
        end
        repeated = declaration[:repeated] == true
        if repeated != field.repeated?
          error(node, :extendee, "\"#{extendee}\" extension field #{field.number} is expected to be " \
            "#{repeated ? "repeated" : "optional"}.")
        end
      end

      def validate_enum(node, enum)
        enum_value_uniqueness(node, enum)
        if enum.open? && !enum.values.empty? && enum.values.first.number != 0
          error(node.value[0], :number, "The first enum value must be zero for open enums.")
        end
        return if enum.options.allow_alias?
        used = {}
        numbers = enum.values.map(&:number)
        enum.values.each_with_index do |value, i|
          if (first, first_index = used[value.number])
            next_value = value.number + 1
            next_value += 1 while numbers.include?(next_value)
            text = "\"#{value.full_name}\" uses the same enum value as \"#{first}\". If this is intended, set " \
              "'option allow_alias = true;' to the enum definition."
            text += " The next available enum value is #{next_value}." if next_value < INT32_MAX
            error(node.value[i], :number, text, related: [[node.value[first_index], :number, "first used by `#{node.value[first_index].name}`"]])
          else
            used[value.number] = [value.full_name, i]
          end
        end
      end

      def enum_value_uniqueness(node, enum)
        prefix = enum.name.delete("_").downcase(:ascii)
        seen = {}
        enum.values.each_with_index do |value, i|
          stripped = pascal_case(remove_prefix(prefix, value.name))
          if (other = seen[stripped])
            next if other.name == value.name || other.number == value.number
            text = "Enum name #{value.name} has the same name as #{other.name} if you ignore case and strip out the " \
              "enum name prefix (if any). (If you are using allow_alias, please assign the same number to each enum " \
              "value name.)"
            if enum.options.deprecated_legacy_json_field_conflicts? && @linker.edition == :EDITION_PROTO2
              warning(node.value[i], :name, text)
            else
              error(node.value[i], :name, text)
            end
          else
            seen[stripped] = value
          end
        end
      end

      def remove_prefix(prefix, name)
        i = 0
        j = 0
        while i < name.size && j < prefix.size
          if name[i] == "_"
            i += 1
            next
          end
          return name if name[i].downcase(:ascii) != prefix[j]
          i += 1
          j += 1
        end
        return name if j < prefix.size
        i += 1 while i < name.size && name[i] == "_"
        return name if i == name.size
        name[i..]
      end

      def pascal_case(name)
        out = +""
        upper = true
        name.each_char do |c|
          if c == "_"
            upper = true
          else
            out << (upper ? c.upcase(:ascii) : c.downcase(:ascii))
            upper = false
          end
        end
        out
      end

      def validate_enum_value(node, value)
        return unless @cli
        problem = feature_support_problem(value.options.feature_support, value.full_name)
        error(node, :option_name, problem) if problem
      end

      def validate_service(node)
        return unless lite?(@file)
        return unless @file.options.cc_generic_services? || @file.options.java_generic_services?
        error(node, :name, "Files with optimize_for = LITE_RUNTIME cannot define services unless you set both " \
          "options cc_generic_services and java_generic_services to false.")
      end

      def edition_value(name)
        Schema::Features::EDITIONS.fetch(name, 0)
      end

      # FeatureResolver::ValidateFeatureSupport
      def feature_support_problem(support, full_name)
        return nil if support.nil?
        if support.key?(:edition_deprecated)
          if edition_value(support[:edition_deprecated]) < edition_value(support[:edition_introduced])
            return "#{full_name} was deprecated before it was introduced."
          end
          unless support.key?(:deprecation_warning)
            return "#{full_name} is deprecated but does not specify a deprecation warning."
          end
        end
        if !support.key?(:edition_deprecated) && support.key?(:deprecation_warning)
          return "#{full_name} specifies a deprecation warning but is not marked deprecated in any edition."
        end
        if support.key?(:edition_removed)
          if edition_value(support[:edition_deprecated]) >= edition_value(support[:edition_removed])
            return "#{full_name} was deprecated after it was removed."
          end
          if edition_value(support[:edition_removed]) < edition_value(support[:edition_introduced])
            return "#{full_name} was removed before it was introduced."
          end
          if support[:edition_introduced] != support[:edition_removed] && !support.key?(:removal_error)
            return "#{full_name} has been removed but does not specify a removal error."
          end
        elsif support.key?(:removal_error)
          return "#{full_name} specifies a removal error but is not marked removed in any edition."
        end
        nil
      end

      def enum_value_support_problem(parent, value, field_name)
        own = value.options.feature_support
        return nil if own.nil? || parent.nil?
        support = parent.merge(own)
        problem = feature_support_problem(support, value.full_name)
        return problem if problem
        if edition_value(support[:edition_introduced]) < edition_value(parent[:edition_introduced])
          return "value #{value.full_name} was introduced before #{field_name} was."
        end
        if parent.key?(:edition_removed) && edition_value(support[:edition_removed]) > edition_value(parent[:edition_removed])
          return "value #{value.full_name} was removed after #{field_name} was."
        end
        if parent.key?(:edition_deprecated) &&
            edition_value(support[:edition_deprecated]) > edition_value(parent[:edition_deprecated])
          return "value #{value.full_name} was deprecated after #{field_name} was."
        end
        nil
      end

      def detect_map_conflicts(message)
        seen = {}
        message.nested_type.each do |nested|
          if (other = seen[nested.name])
            if map_entry?(other) || map_entry?(nested)
              error(message, :name, "Expanded map entry type #{nested.name} conflicts with an existing nested " \
                "message type.")
              break
            end
          else
            seen[nested.name] = nested
          end
          detect_map_conflicts(nested)
        end
        message.field.each do |field|
          other = seen[field.name]
          if other && map_entry?(other)
            error(message, :name, "Expanded map entry type #{other.name} conflicts with an existing field.")
          end
        end
        message.enum_type.each do |enum|
          other = seen[enum.name]
          if other && map_entry?(other)
            error(message, :name, "Expanded map entry type #{other.name} conflicts with an existing enum type.")
          end
        end
        message.oneof_decl.each do |oneof|
          other = seen[oneof.name]
          if other && map_entry?(other)
            error(message, :name, "Expanded map entry type #{other.name} conflicts with an existing oneof type.")
          end
        end
      end

      def map_entry?(message)
        message.options&.known&.[](:map_entry) == true
      end

      def unused_imports
        @linker.table.unused.each do |name|
          @linker.import_warning(name, "Import #{name} is unused.")
        end
      end

      def style_at_least?(features, style)
        order = {STYLE_LEGACY: -1, STYLE2024: 1, STYLE2026: 2}
        features.enforce_naming_style != :STYLE_LEGACY &&
          order.fetch(features.enforce_naming_style, 0) >= order.fetch(style)
      end

      def naming_style(node, kind)
        return if kind == :extension_range
        descriptor = schema_of(node, kind)
        return unless style_at_least?(descriptor.features, :STYLE2024)
        case kind
        when :file
          return if @file.package.empty?
          problem = lower_snake_case_problem(@file.package)
          error(@ast, :name, "Package name #{@file.package} #{problem}#{NAMING_OPT_OUT}") if problem
        when :message, :enum, :service, :method
          problem = title_case_problem(node.name)
          label = {message: "Message", enum: "Enum", service: "Service", method: "Method"}.fetch(kind)
          error(node, :name, "#{label} name #{node.name} #{problem}#{NAMING_OPT_OUT}") if problem
        when :oneof, :field
          label = (kind == :oneof) ? "Oneof" : "Field"
          problem = lower_snake_case_problem(node.name)
          error(node, :name, "#{label} name #{node.name} #{problem}#{NAMING_OPT_OUT}") if problem
          if style_at_least?(descriptor.features, :STYLE2026) && (collision = collision_problem(node, kind))
            error(node, :name, "#{label} name #{node.name} #{collision}#{COLLISION_OPT_OUT}")
          end
        when :enum_value
          problem = upper_snake_case_problem(node.name)
          error(node, :name, "Enum value name #{node.name} #{problem}#{NAMING_OPT_OUT}") if problem
        end
      end

      def collision_problem(node, kind)
        name = node.name
        message = (kind == :oneof || !node.extension) ? node.parent : nil
        if message
          %w[has_ get_ set_ clear_].each do |prefix|
            next unless name.start_with?(prefix)
            rest = name.delete_prefix(prefix)
            if message.field.any? { |f| f.name == rest } || message.oneof_decl.any? { |o| o.name == rest }
              return "should not begin with #{prefix} if a field named #{rest} exists. This can cause collisions in " \
                "generated code."
            end
          end
          if name.end_with?("_value")
            rest = name.delete_suffix("_value")
            if message.field.any? { |f| f.name == rest } || message.oneof_decl.any? { |o| o.name == rest }
              return "should not end with _value if a field named #{rest} exists. This can cause collisions in " \
                "generated code."
            end
          end
        end
        return "should not be named descriptor. This can cause collisions in generated code." if name == "descriptor"
        nil
      end

      def bad_underscores?(name)
        return false if name.empty?
        return true if name.start_with?("_") || name.end_with?("_")
        (1...name.size).any? { |i| name[i - 1] == "_" && !name[i].match?(/[A-Za-z]/) }
      end

      def title_case_problem(name)
        return "is empty" if name.empty?
        return "should be TitleCase" unless name.match?(/\A[A-Za-z0-9]+\z/)
        return "should begin with a capital letter" unless name.match?(/\A[A-Z]/)
        nil
      end

      def lower_snake_case_problem(name)
        return "is empty" if name.empty?
        return "should be lower_snake_case" unless name.match?(/\A[a-z0-9_.]+\z/)
        return "should begin with a lower case letter" unless name.match?(/\A[a-z]/)
        return "contains style violating underscores" if bad_underscores?(name)
        nil
      end

      def upper_snake_case_problem(name)
        return "is empty" if name.empty?
        return "should be UPPER_SNAKE_CASE" unless name.match?(/\A[A-Z0-9_]+\z/)
        return "should begin with an upper case letter" unless name.match?(/\A[A-Z]/)
        return "contains style violating underscores" if bad_underscores?(name)
        nil
      end

      def proto_limits(node, kind)
        return unless %i[message oneof enum].include?(kind)
        descriptor = schema_of(node, kind)
        return if descriptor.features.enforce_proto_limits == :LEGACY_NO_EXPLICIT_LIMITS
        case kind
        when :message
          if descriptor.fields.size > LIMIT_FIELDS_PER_MESSAGE
            error(node, :name, "Message name #{node.name} should not contain more than #{LIMIT_FIELDS_PER_MESSAGE} " \
              "fields#{LIMITS_OPT_OUT}")
          end
          if descriptor.real_oneofs.size > LIMIT_ONEOFS_PER_MESSAGE
            error(node, :name, "Message name #{node.name} should not contain more than #{LIMIT_ONEOFS_PER_MESSAGE} " \
              "oneofs#{LIMITS_OPT_OUT}")
          end
        when :oneof
          if descriptor.fields.size > LIMIT_FIELDS_PER_ONEOF
            error(node, :name, "Oneof name #{node.name} should not contain more than #{LIMIT_FIELDS_PER_ONEOF} " \
              "fields#{LIMITS_OPT_OUT}")
          end
        when :enum
          if descriptor.values.size > LIMIT_VALUES_PER_ENUM
            error(node, :name, "Enum name #{node.name} should not contain more than #{LIMIT_VALUES_PER_ENUM} " \
              "values#{LIMITS_OPT_OUT}")
          end
        end
      end

      def symbol_visibility
        strict = @file.features.default_symbol_visibility == :STRICT
        each_element do |node, kind|
          next if kind != :message && kind != :enum
          next if node.parent.nil?
          next unless node.visibility == :VISIBILITY_EXPORT
          descriptor = schema_of(node, kind)
          next unless descriptor.features.default_symbol_visibility == :STRICT || strict
          next if kind == :enum && namespaced_enum?(descriptor)
          if kind == :message
            error(node, :other, "\"#{node.full_name}\" is a nested message and cannot be `export` with STRICT " \
              "default_symbol_visibility. It must be moved to top-level, ideally in its own file in order to be " \
              "`export`.")
          else
            error(node, :other, "\"#{node.full_name}\" is a nested enum and cannot be marked `export` with STRICT " \
              "default_symbol_visibility. It must be moved to top-level, ideally in its own file in order to be " \
              "`export`. For C++ namespacing of enums in a messages use: `local message <OuterNamespace> { export " \
              "enum #{node.full_name} {...} reserved 1 to max; }`")
          end
        end
      end

      def namespaced_enum?(enum)
        container = enum.containing_message
        return false unless container
        local_default = %i[STRICT LOCAL_ALL].include?(@file.features.default_symbol_visibility)
        exported = !local_default || enum.visibility == :export
        return false unless exported
        return false if container.containing_message
        local = container.visibility == :local || (container.visibility.nil? && local_default)
        return false unless local
        container.reserved_ranges.size == 1 && container.reserved_ranges[0] == (1..MAX_FIELD_NUMBER)
      end

      # FeatureResolver::ValidateFeatureLifetimes over every element's
      # features and options
      def feature_lifetimes
        edition = @linker.edition_number
        each_element do |node, kind|
          next unless node.options
          options = schema_of(node, kind).options
          next if options.empty?
          type = options_message(kind)
          features = options[:features]
          if features && (feature_type = type.fields_by_name["features"]&.message_type)
            lifetimes(features, feature_type, edition, node)
          end
          # protoc moves features out of the options before this check
          lifetimes(options, type, edition, node, except: :features)
        end
      end

      def lifetimes(value, type, edition, node, except: nil)
        fields = value.fields.filter_map do |name, v|
          [type.fields_by_name[name.to_s], v] unless name == except
        end
        (fields + value.extensions.to_a).each do |field, v|
          next unless field.is_a?(Schema::Field)
          if field.type == :message || field.type == :group
            (field.repeated? ? v : [v]).each do |m|
              lifetimes(m, field.message_type, edition, node) if m.is_a?(Schema::MessageValue)
            end
          end
          if field.type == :enum
            (field.repeated? ? v : [v]).each do |name|
              enum_value = field.enum_type.value(name.is_a?(Symbol) ? name.to_s : name)
              single_lifetime(edition, enum_value.full_name, enum_value.options.feature_support, node) if enum_value
            end
          end
          single_lifetime(edition, field.full_name, field.options.feature_support, node)
        end
      end

      def single_lifetime(edition, full_name, support, node)
        return if support.nil?
        if edition < edition_value(support[:edition_introduced])
          error(node, :name, "#{full_name} wasn't introduced until edition " \
            "#{edition_label(support[:edition_introduced])} and can't be used in edition #{edition_label(@linker.edition)}")
        end
        if support.key?(:edition_removed) && edition >= edition_value(support[:edition_removed])
          suffix = support.key?(:removal_error) ? ": #{support[:removal_error]}" : ""
          error(node, :name, "#{full_name} has been removed in edition #{edition_label(support[:edition_removed])}#{suffix}")
        elsif support.key?(:edition_deprecated) && edition >= edition_value(support[:edition_deprecated])
          return unless @linker.direct?
          warning(node, :name, "#{full_name} has been deprecated in edition " \
            "#{edition_label(support[:edition_deprecated])}: #{support[:deprecation_warning]}")
        end
      end

      def edition_label(edition)
        edition.to_s.delete_prefix("EDITION_")
      end
    end
  end
end
