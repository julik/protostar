# frozen_string_literal: true

module Protostar
  class Compiler
    # Links one parsed file against the pool, the way protoc's
    # DescriptorBuilder does: drafts a {Schema::File} as it registers the
    # file's symbols, resolves every name onto the draft, interprets options
    # into it, and freezes it. It reports protoc's errors in protoc's order,
    # each against the AST node and location kind protoc reports it at;
    # {Validator} adds the checks protoc runs once the file is built.
    #
    # @api private
    class Linker
      # One error or warning
      class Problem
        # @return [Symbol] :error or :warning
        attr_reader :severity
        # @return [AST::Node, nil] whose recorded position protoc reports, nil for none
        attr_reader :node
        # @return [Symbol, nil] the kind of position (:name, :number, ...), or :import
        attr_reader :location
        # @return [String]
        attr_reader :message
        # @return [String, nil] for an :import problem, the imported file name
        attr_reader :import

        def initialize(severity:, message:, node: nil, location: nil, import: nil)
          @severity = severity
          @node = node
          @location = location
          @message = message
          @import = import
          freeze
        end

        def error?
          @severity == :error
        end
      end

      MAX_FIELD_NUMBER = 536_870_911
      INT32_MAX = 2**31 - 1
      LEGACY_EDITIONS = %i[EDITION_PROTO2 EDITION_PROTO3].freeze
      MINIMUM_EDITION = :EDITION_PROTO2
      MAXIMUM_EDITION = :EDITION_2026

      OPTIONS_TYPES = {
        file: "google.protobuf.FileOptions", message: "google.protobuf.MessageOptions",
        field: "google.protobuf.FieldOptions", oneof: "google.protobuf.OneofOptions",
        extension_range: "google.protobuf.ExtensionRangeOptions", enum: "google.protobuf.EnumOptions",
        enum_value: "google.protobuf.EnumValueOptions", service: "google.protobuf.ServiceOptions",
        method: "google.protobuf.MethodOptions"
      }.freeze

      # The options of one element awaiting interpretation
      class Pending
        # @return [AST::Node]
        attr_reader :node
        # @return [Symbol] which options message applies: a key of {OPTIONS_TYPES}
        attr_reader :kind
        # @return [String] the scope custom option names are looked up from
        attr_reader :name_scope
        # @return [Array<Integer>] source path of the element's `options` field
        attr_reader :path

        def initialize(node:, kind:, name_scope:, path:)
          @node = node
          @kind = kind
          @name_scope = name_scope
          @path = path
          freeze
        end

        # @return [AST::Options] the uninterpreted options
        def options
          @node.options
        end
      end

      # @return [Array<Problem>]
      attr_reader :problems
      # @return [AST::File]
      attr_reader :ast
      # @return [SymbolTable]
      attr_reader :table
      # @return [Schema::Pool]
      attr_reader :pool
      # @return [Symbol] the file's edition (EDITION_PROTO2 or EDITION_PROTO3 for legacy syntax)
      attr_reader :edition
      # @return [Schema::File, nil] the built file, when linking succeeded
      attr_reader :file
      # @return [Array<SourceInfo::Location>] locations after option paths were rewritten
      attr_reader :locations

      # @param ast [AST::File]
      # @param pool [Schema::Pool] holds every import that could be compiled
      # @param missing [Array<String>] imports that could not be found or compiled
      # @param direct [Boolean] whether the file was named on the command line
      #   (unused imports are only reported for those)
      # @param options_fallback [#call] returns the bundled descriptor.proto's
      #   options message for a name, when the pool has no descriptor.proto
      # @param protoc_cli [Boolean] apply what protoc's command line enables on
      #   top of a plain DescriptorPool: imports loaded from disk, unused import
      #   warnings, naming style, proto limits, symbol visibility and
      #   feature support checks
      def initialize(ast, pool:, missing: [], direct: true, options_fallback: nil, source_info: false,
        protoc_cli: true)
        @ast = ast
        @protoc_cli = protoc_cli
        @source_info = source_info
        @pool = pool
        @missing = missing
        @direct = direct
        @options_fallback = options_fallback
        @problems = []
        @pending = []
        @hints = {}
        @locations = ast.locations
        @descriptors = {}.compare_by_identity
      end

      # @return [OptionInterpreter, nil] set once options have been interpreted
      attr_reader :interpreter

      def protoc_cli?
        @protoc_cli
      end

      # @return [Boolean] whether the file was named on the command line
      def direct?
        @direct
      end

      # @return [Array<Schema::File, nil>] the direct imports, nil where missing
      attr_reader :dependency_files

      # @return [Boolean] whether any error was reported
      def errors?
        @problems.any?(&:error?)
      end

      # Runs every phase up to building the {Schema::File}
      # @return [Schema::File, nil]
      def link
        setup_edition
        setup_symbols
        build_file
        cross_link
        suggest_field_numbers
        unless errors?
          interpret_options
          build_schema unless errors?
        end
        @file
      end

      # @return [Schema::Draft::File] the file as drafted so far
      attr_reader :draft

      # The descriptor drafted for an AST node: the file, a message, field,
      # oneof, extension range, enum, enum value, service or method
      # @return [Schema::Descriptor, nil]
      def descriptor_of(node)
        node.is_a?(AST::File) ? @draft.descriptor : @descriptors[node]
      end

      # Every element in protoc's VisitDescriptors order, as [node, kind]
      def each_element(&block)
        return enum_for(:each_element) unless block
        yield @ast, :file
        @ast.message_type.each { |m| visit_message(m, &block) }
        @ast.enum_type.each { |e| visit_enum(e, &block) }
        @ast.extension.each { |f| yield f, :field }
        @ast.service.each do |s|
          yield s, :service
          s.rpcs.each { |m| yield m, :method }
        end
      end

      # Records an error against a node's recorded position
      def error(node, location, message)
        @problems << Problem.new(severity: :error, node: node, location: location, message: message)
      end

      def warning(node, location, message)
        @problems << Problem.new(severity: :warning, node: node, location: location, message: message)
      end

      def import_error(name, message)
        @problems << Problem.new(severity: :error, location: :import, message: message, import: name)
      end

      def import_warning(name, message)
        @problems << Problem.new(severity: :warning, location: :import, message: message, import: name)
      end

      # @return [Integer]
      def edition_number
        Schema::Features::EDITIONS.fetch(@edition)
      end

      def legacy?
        LEGACY_EDITIONS.include?(@edition)
      end

      private

      def visit_message(message, &block)
        yield message, :message
        message.enum_type.each { |e| visit_enum(e, &block) }
        message.oneof_decl.each { |o| yield o, :oneof }
        message.field.each { |f| yield f, :field }
        message.nested_type.each { |n| visit_message(n, &block) }
        message.extension.each { |f| yield f, :field }
        message.extension_range.each { |r| yield r, :extension_range }
      end

      def visit_enum(enum)
        yield enum, :enum
        enum.value.each { |v| yield v, :enum_value }
      end

      def setup_edition
        @edition = if @ast.edition
          @ast.edition
        elsif @ast.syntax == "proto3"
          :EDITION_PROTO3
        else
          :EDITION_PROTO2
        end
        number = edition_number
        if number < Schema::Features::EDITIONS.fetch(MINIMUM_EDITION)
          error(@ast, :editions, "Edition #{edition_label(@edition)} is earlier than the minimum supported edition " \
            "#{edition_label(MINIMUM_EDITION)}")
        elsif number > Schema::Features::EDITIONS.fetch(MAXIMUM_EDITION) && @edition != :EDITION_UNSTABLE
          error(@ast, :editions, "Edition #{edition_label(@edition)} is later than the maximum supported edition " \
            "#{edition_label(MAXIMUM_EDITION)}")
        end
      end

      # How absl prints an Edition: the enum name without its prefix
      def edition_label(edition)
        edition.to_s.delete_prefix("EDITION_")
      end

      # AddImportError: protoc's command line loads imports on demand, a bare pool does not
      def missing_import_message(name)
        if @protoc_cli
          "Import \"#{name}\" was not found or had errors."
        else
          "Import \"#{name}\" has not been loaded."
        end
      end

      def setup_symbols
        dependencies = []
        unused = []
        seen = {}
        names = @ast.dependency + @ast.option_dependency
        option_files = []
        names.each_with_index do |name, i|
          option = i >= @ast.dependency.size
          import_error(name, "Import \"#{name}\" was listed twice.") if seen[name]
          seen[name] = true
          dep = @pool.file(name)
          dep = nil if @missing.include?(name)
          if dep.nil?
            import_error(name, missing_import_message(name)) unless option
          elsif @direct && dep.public_dependencies.empty? && !option
            unused << dep
          end
          option ? option_files << dep : dependencies << dep
        end
        @ast.public_dependency.each { |i| unused.delete(dependencies[i]) }
        @dependency_files = dependencies
        @table = SymbolTable.new(@ast.name, @ast.package.to_s, @pool, dependencies, option_files, unused)
        @unknown_option_imports = @ast.option_dependency.each_with_index.select { |_, i| option_files[i].nil? }.map(&:first)
      end

      def build_file
        package = @ast.package.to_s
        unless package.empty?
          if (existing = @table.add_package(package))
            error(@ast, :name, "\"#{existing.full_name}\" is already defined (as something other than a package) " \
              "in file \"#{existing.file_name}\".")
          end
        end
        @ast.full_name = @ast.name
        @ast.path = []
        @draft = Schema::File.draft(@ast.name, package: package, syntax: draft_syntax,
          edition: legacy? ? nil : @edition, dependencies: @ast.dependency,
          public_dependencies: @ast.public_dependency, weak_dependencies: @ast.weak_dependency,
          option_dependencies: @ast.option_dependency)
        @ast.message_type.each_with_index { |m, i| build_message(m, nil, i, [4, i], @draft) }
        @ast.enum_type.each_with_index { |e, i| build_enum(e, nil, i, [5, i], @draft) }
        @ast.service.each_with_index { |s, i| build_service(s, i) }
        @ast.extension.each_with_index { |f, i| build_field(f, nil, i, [7, i], @draft, extension: true) }
        pend(@ast, :file, "#{package}.dummy", [8])
        @draft.__seal
      end

      # protoc's CopyTo writes no `syntax` for proto2
      def draft_syntax
        case @edition
        when :EDITION_PROTO2 then nil
        when :EDITION_PROTO3 then :proto3
        else :editions
        end
      end

      def scope_of(parent)
        parent ? parent.full_name : @ast.package.to_s
      end

      def qualify(scope, name)
        scope.empty? ? name : "#{scope}.#{name}"
      end

      def pend(node, kind, name_scope, path)
        return unless node.options
        @pending << Pending.new(node: node, kind: kind, name_scope: name_scope, path: path)
      end

      def add_symbol(kind, node, full_name)
        existing = @table.add(kind, full_name, descriptor_of(node))
        return true unless existing
        if existing.file_name == @ast.name
          dot = full_name.rindex(".")
          if dot
            error(node, :name, "\"#{full_name[(dot + 1)..]}\" is already defined in \"#{full_name[0, dot]}\".")
          else
            error(node, :name, "\"#{full_name}\" is already defined.")
          end
        else
          error(node, :name, "\"#{full_name}\" is already defined in file \"#{existing.file_name}\".")
        end
        false
      end

      def hint(message, reason, location, from = 0, to = 1)
        fit = ->(v) { v.clamp(0, MAX_FIELD_NUMBER) }
        h = (@hints[message] ||= {count: 0, reason: nil, location: nil})
        h[:count] = fit.call(h[:count] + fit.call(fit.call(to) - fit.call(from)))
        return if h[:reason]
        h[:reason] = reason
        h[:location] = location
      end

      def build_message(message, parent, index, path, scope)
        message.parent = parent
        message.index = index
        message.path = path
        message.full_name = qualify(scope_of(parent), message.name)
        full_name = message.full_name
        draft = scope.message(message.name, visibility: message.visibility)
        @descriptors[message] = draft.descriptor

        oneofs = message.oneof_decl.each_with_index.map do |oneof, i|
          oneof.parent = message
          oneof.index = i
          oneof.path = path + [8, i]
          oneof.full_name = "#{full_name}.#{oneof.name}"
          @descriptors[oneof] = draft.oneof(oneof.name)
          pend(oneof, :oneof, oneof.full_name, oneof.path + [2])
          add_symbol(:oneof, oneof, oneof.full_name)
          @descriptors[oneof]
        end
        message.field.each_with_index do |f, i|
          build_field(f, message, i, path + [2, i], draft, extension: false, oneofs: oneofs)
        end
        message.enum_type.each_with_index { |e, i| build_enum(e, message, i, path + [4, i], draft) }
        message.extension_range.each_with_index do |range, i|
          range.parent = message
          range.index = i
          range.path = path + [5, i]
          range.full_name = full_name
          @descriptors[range] = draft.extension_range(range.start..(range.end - 1))
          if range.start <= 0
            hint(message, range, :number, range.start, range.end)
            error(range, :number, "Extension numbers must be positive integers.")
          end
          if range.start >= range.end
            error(range, :number, "Extension range end number must be greater than start number.")
          end
          pend(range, :extension_range, full_name, range.path + [3])
        end
        message.extension.each_with_index { |f, i| build_field(f, message, i, path + [6, i], draft, extension: true) }
        message.reserved_range.each do |range|
          draft.reserved(range.start..(range.end - 1))
          if range.start <= 0
            hint(message, range, :number, range.start, range.end)
            error(range, :number, "Reserved numbers must be positive integers.")
          end
          if range.start >= range.end
            error(range, :number, "Reserved range end number must be greater than start number.")
          end
        end
        draft.reserved(*message.reserved_name)
        pend(message, :message, full_name, path + [7])
        message.nested_type.each_with_index { |m, i| build_message(m, message, i, path + [3, i], draft) }
        add_symbol(:message, message, full_name)

        ranges = message.reserved_range
        ranges.each_with_index do |r1, i|
          ranges[(i + 1)..].each do |r2|
            next unless r1.end > r2.start && r2.end > r1.start
            error(r1, :number, "Reserved range #{r2.start} to #{r2.end - 1} overlaps with already-defined range " \
              "#{r1.start} to #{r1.end - 1}.")
          end
        end
        reserved_names = {}
        message.reserved_name.each do |name|
          if reserved_names[name]
            error(message, :name, "Field name \"#{name}\" is reserved multiple times.")
          end
          reserved_names[name] = true
        end
        message.field.each do |field|
          message.extension_range.each do |range|
            next unless range.start <= field.number && field.number < range.end
            hint(message, range, :number)
            error(range, :number, "Extension range #{range.start} to #{range.end - 1} includes field " \
              "\"#{field.name}\" (#{field.number}).")
          end
          ranges.each do |range|
            next unless range.start <= field.number && field.number < range.end
            hint(message, range, :number)
            error(range, :number, "Field \"#{field.name}\" uses reserved number #{field.number}.")
          end
          error(field, :name, "Field name \"#{field.name}\" is reserved.") if reserved_names[field.name]
        end
        message.extension_range.each_with_index do |r1, i|
          ranges.each do |r2|
            next unless r1.end > r2.start && r2.end > r1.start
            error(r1, :number, "Extension range #{r1.start} to #{r1.end - 1} overlaps with reserved range " \
              "#{r2.start} to #{r2.end - 1}.")
          end
          message.extension_range[(i + 1)..].each do |r2|
            next unless r1.end > r2.start && r2.end > r1.start
            error(r1, :number, "Extension range #{r2.start} to #{r2.end - 1} overlaps with already-defined range " \
              "#{r1.start} to #{r1.end - 1}.")
          end
        end
      end

      def build_field(field, parent, index, path, scope, extension:, oneofs: nil)
        field.parent = parent
        field.index = index
        field.path = path
        field.extension = extension
        field.full_name = qualify(scope_of(parent), field.name)
        type = field.type && Schema::Field::TYPES.fetch(field.type)
        kwargs = {label: Schema::Field::LABELS.fetch(field.label || :LABEL_OPTIONAL),
                  default: field.default_value && default_text(field), json_name: field.json_name,
                  optional: field.proto3_optional ? true : false}
        @descriptors[field] = if extension
          scope.extension(field.name, field.number, type, field.type_name, extendee: field.extendee, **kwargs)
        else
          oneof = field.oneof_index && oneofs[field.oneof_index]
          scope.field(field.name, field.number, type, field.type_name, oneof: oneof, **kwargs)
        end
        if field.label == :LABEL_REQUIRED && extension
          error(field, :type, "The extension #{field.full_name} cannot be required.")
        end
        if field.default_value && field.label == :LABEL_REPEATED
          error(field, :default_value, "Repeated fields can't have default values.")
        end
        if field.type && field.default_value
          case field.type
          when :TYPE_BOOL
            unless %w[true false].include?(field.default_value)
              error(field, :default_value, "Boolean default must be true or false.")
            end
          when :TYPE_BYTES
            error(field, :default_value, "Invalid escaping in default value.") unless c_unescape(field.default_value)
          when :TYPE_MESSAGE, :TYPE_GROUP
            error(field, :default_value, "Messages can't have default values.")
          end
        end
        if field.number <= 0
          hint(parent, field, :number)
          error(field, :number, "Field numbers must be positive integers.")
        elsif !extension && field.number > MAX_FIELD_NUMBER
          hint(parent, field, :number)
          error(field, :number, "Field numbers cannot be greater than #{MAX_FIELD_NUMBER}.")
        end
        pend(field, :field, field.full_name, path + [8])
        add_symbol(:field, field, field.full_name)
      end

      def build_enum(enum, parent, index, path, scope_draft)
        enum.parent = parent
        enum.index = index
        enum.path = path
        scope = scope_of(parent)
        enum.full_name = qualify(scope, enum.name)
        draft = scope_draft.enum(enum.name, visibility: enum.visibility)
        @descriptors[enum] = draft.descriptor
        error(enum, :name, "Enums must contain at least one value.") if enum.value.empty?
        inner = {}
        enum.value.each_with_index do |value, i|
          value.parent = enum
          value.index = i
          value.path = path + [2, i]
          value.full_name = qualify(scope, value.name)
          @descriptors[value] = draft.value(value.name, value.number)
          pend(value, :enum_value, value.full_name, value.path + [3])
          added_outer = add_symbol(:enum_value, value, value.full_name)
          added_inner = !inner.key?(value.name)
          inner[value.name] = true
          next unless added_inner && !added_outer
          outer = parent ? parent.full_name : @ast.package.to_s
          outer = outer.empty? ? "the global scope" : "\"#{outer}\""
          error(value, :name, "Note that enum values use C++ scoping rules, meaning that enum values are siblings " \
            "of their type, not children of it.  Therefore, \"#{value.name}\" must be unique within #{outer}, not " \
            "just within \"#{enum.name}\".")
        end
        pend(enum, :enum, enum.full_name, path + [3])
        add_symbol(:enum, enum, enum.full_name)

        ranges = enum.reserved_range
        ranges.each { |range| draft.reserved(range.start..range.end) }
        draft.reserved(*enum.reserved_name)
        ranges.each do |range|
          if range.start > range.end
            error(range, :number, "Reserved range end number must be greater than start number.")
          end
        end
        ranges.each_with_index do |r1, i|
          ranges[(i + 1)..].each do |r2|
            next unless r1.end >= r2.start && r2.end >= r1.start
            error(r1, :number, "Reserved range #{r2.start} to #{r2.end} overlaps with already-defined range " \
              "#{r1.start} to #{r1.end}.")
          end
        end
        reserved_names = {}
        enum.reserved_name.each do |name|
          error(enum, :name, "Enum value \"#{name}\" is reserved multiple times.") if reserved_names[name]
          reserved_names[name] = true
        end
        enum.value.each do |value|
          ranges.each do |range|
            next unless value.number.between?(range.start, range.end)
            error(range, :number, "Enum value \"#{value.name}\" uses reserved number #{value.number}.")
          end
          error(value, :name, "Enum value \"#{value.name}\" is reserved.") if reserved_names[value.name]
        end
      end

      def build_service(service, index)
        service.index = index
        service.path = [6, index]
        service.full_name = qualify(@ast.package.to_s, service.name)
        draft = @draft.service(service.name)
        @descriptors[service] = draft.descriptor
        service.rpcs.each_with_index do |method, i|
          method.parent = service
          method.index = i
          method.path = service.path + [2, i]
          method.full_name = "#{service.full_name}.#{method.name}"
          @descriptors[method] = draft.rpc(method.name, method.input_type, method.output_type,
            client_streaming: method.client_streaming, server_streaming: method.server_streaming)
          pend(method, :method, method.full_name, method.path + [4])
          add_symbol(:method, method, method.full_name)
        end
        pend(service, :service, service.full_name, service.path + [3])
        add_symbol(:service, service, service.full_name)
      end

      def cross_link
        @fields_by_number = {}
        @ast.message_type.each { |m| cross_link_message(m) }
        @ast.extension.each { |f| cross_link_field(f) }
        @ast.service.each { |s| s.rpcs.each { |m| cross_link_method(m) } }
      end

      def cross_link_message(message)
        message.nested_type.each { |m| cross_link_message(m) }
        message.field.each { |f| cross_link_field(f) }
        message.extension.each { |f| cross_link_field(f) }

        counts = Hash.new(0)
        message.field.each_with_index do |field, i|
          next unless field.oneof_index
          oneof = message.oneof_decl[field.oneof_index]
          next unless oneof
          if counts[oneof] > 0 && message.field[i - 1].oneof_index != field.oneof_index
            prev = message.field[i - 1]
            error(prev, :type, "Fields in the same oneof must be defined consecutively. \"#{prev.name}\" cannot be " \
              "defined before the completion of the \"#{oneof.name}\" oneof definition.")
          end
          counts[oneof] += 1
        end
        message.oneof_decl.each do |oneof|
          error(oneof, :name, "Oneof must have at least one field.") if counts[oneof] == 0
        end
      end

      def not_defined(node, location, name)
        @table.not_defined_messages(name).each { |m| error(node, location, m) }
      end

      def cross_link_field(field)
        holder = field.parent
        if field.extension
          extendee = @table.lookup(field.extendee, field.full_name)
          if extendee.nil?
            not_defined(field, :extendee, field.extendee)
            return
          elsif extendee.kind != :message
            error(field, :extendee, "\"#{field.extendee}\" is not a message type.")
            return
          end
          return unless visible?(extendee, field, :extendee, "target of extend")
          @draft.__resolve_extendee(descriptor_of(field), extendee.object)
          holder = extendee
          unless extension_number?(extendee, field.number)
            error(field, :number, "\"#{extendee.full_name}\" does not declare #{field.number} as an extension number.")
          end
        end

        if field.oneof_index && field.label != :LABEL_OPTIONAL
          error(field, :name, "Fields of oneofs must themselves have label LABEL_OPTIONAL.")
        end

        if field.type_name
          type = @table.lookup(field.type_name, field.full_name, types_only: true)
          if type.nil?
            not_defined(field, :type, field.type_name)
            return
          end
          return unless visible?(type, field, :type)
          if field.type.nil? && !type.type?
            error(field, :type, "\"#{field.type_name}\" is not a type.")
            return
          end
          kind = if field.type
            %i[TYPE_MESSAGE TYPE_GROUP].include?(field.type) ? :message : :enum
          else
            type.kind
          end
          if kind == :message
            if type.kind != :message
              error(field, :type, "\"#{field.type_name}\" is not a message type.")
              return
            end
            @draft.__resolve_type(descriptor_of(field), type.object)
            error(field, :default_value, "Messages can't have default values.") if field.default_value
          else
            if type.kind != :enum
              error(field, :type, "\"#{field.type_name}\" is not an enum type.")
              return
            end
            @draft.__resolve_type(descriptor_of(field), type.object)
            if field.default_value
              if !Lexer.identifier?(field.default_value)
                error(field, :default_value, "Default value for an enum field must be an identifier.")
              elsif !enum_value_names(type).include?(field.default_value)
                error(field, :default_value, "Enum type \"#{type.full_name}\" has no value named " \
                  "\"#{field.default_value}\".")
              end
            end
          end
        end

        key = [holder_key(holder), field.number]
        if (conflict = @fields_by_number[key])
          holder_name = holder ? holder.full_name : "unknown"
          if field.extension
            error(field, :number, "Extension number #{field.number} has already been used in \"#{holder_name}\" by " \
              "extension \"#{conflict.full_name}\".")
          else
            error(field, :number, "Field number #{field.number} has already been used in \"#{holder_name}\" by field " \
              "\"#{conflict.name}\". #{next_available_number(field.parent)}.")
          end
        else
          @fields_by_number[key] = field
          if field.extension && (other = @pool.find_extension(holder.full_name, field.number))
            warning(field, :number, "Extension number #{field.number} has already been used in " \
              "\"#{holder.full_name}\" by extension \"#{other.full_name}\" defined in #{other.file.name}.")
          end
        end
      end

      def holder_key(holder)
        holder&.full_name
      end

      def next_available_number(message)
        used = message.field.map { |f| [f.number, f.number] }
        message.extension_range.each { |r| used << [r.start, r.end - 1] }
        message.reserved_range.each { |r| used << [r.start, r.end - 1] }
        proposed = 1
        used.uniq.sort.each do |first, last|
          break unless proposed.between?(first, last)
          proposed = last + 1
        end
        (proposed <= MAX_FIELD_NUMBER) ? "Next available field number is #{proposed}" : "There are no available field numbers"
      end

      def extension_number?(symbol, number)
        symbol.object.extension_number?(number)
      end

      def enum_value_names(symbol)
        symbol.object.values.map(&:name)
      end

      # Symbol::IsVisibleFrom: edition 2024 `local` types are invisible outside their file
      def visible?(symbol, node, location, usage = "")
        return true unless @protoc_cli
        return true unless symbol.type? && !symbol.local?
        descriptor = symbol.object
        visibility = descriptor.visibility
        if visibility.nil? || visibility == :VISIBILITY_UNSET
          visibility = case descriptor.features.default_symbol_visibility
          when :EXPORT_ALL then :VISIBILITY_EXPORT
          when :EXPORT_TOP_LEVEL then descriptor.containing_message ? :VISIBILITY_LOCAL : :VISIBILITY_EXPORT
          when :LOCAL_ALL, :STRICT then :VISIBILITY_LOCAL
          else :VISIBILITY_EXPORT
          end
          explicit = false
        else
          explicit = true
        end
        return true if visibility == :VISIBILITY_EXPORT
        reason = if explicit && descriptor.visibility == :VISIBILITY_LOCAL
          "It is explicitly marked 'local'"
        else
          "It defaulted to local from file-level 'option features.default_symbol_visibility = " \
            "'#{descriptor.features.default_symbol_visibility}';"
        end
        error(node, location, "Symbol \"#{descriptor.full_name}\", defined in \"#{descriptor.file.name}\" #{usage} " \
          "is not visible from \"#{@ast.name}\". #{reason} and cannot be accessed outside its own file")
        false
      end

      def cross_link_method(method)
        input = @table.lookup(method.input_type, method.full_name)
        if input.nil?
          not_defined(method, :input_type, method.input_type)
        elsif input.kind != :message
          error(method, :input_type, "\"#{method.input_type}\" is not a message type.")
        elsif visible?(input, method, :input_type)
          @draft.__resolve_rpc(descriptor_of(method), input: input.object)
        end
        output = @table.lookup(method.output_type, method.full_name)
        if output.nil?
          not_defined(method, :output_type, method.output_type)
        elsif output.kind != :message
          error(method, :output_type, "\"#{method.output_type}\" is not a message type.")
        elsif visible?(output, method, :output_type)
          @draft.__resolve_rpc(descriptor_of(method), output: output.object)
        end
      end

      def suggest_field_numbers
        @ast.message_type.each do |message|
          h = @hints[message]
          next unless h
          count = [3, h[:count]].min
          next if count <= 0
          used = []
          add_ordinal = lambda do |n|
            next if n <= 0 || n > MAX_FIELD_NUMBER
            if !used.empty? && n == used.last[1]
              used.last[1] = n + 1
            else
              used << [n, n + 1]
            end
          end
          add_range = lambda do |from, to|
            from = from.clamp(0, MAX_FIELD_NUMBER + 1)
            to = to.clamp(0, MAX_FIELD_NUMBER + 1)
            used << [from, to] if from < to
          end
          message.field.each { |f| add_ordinal.call(f.number) }
          message.extension.each { |f| add_ordinal.call(f.number) }
          message.reserved_range.each { |r| add_range.call(r.start, r.end) }
          message.extension_range.each { |r| add_range.call(r.start, r.end) }
          used << [MAX_FIELD_NUMBER, MAX_FIELD_NUMBER + 1]
          used << [19_000, 19_999]
          used.sort!
          current = 1
          ids = []
          used.each do |from, to|
            while current < from && count > 0
              ids << current
              current += 1
              count -= 1
            end
            break if count == 0
            current = [current, to].max
          end
          error(h[:reason], h[:location], "Suggested field numbers for #{message.full_name}: #{ids.join(", ")}")
        end
      end

      def interpret_options
        unless @pending.empty?
          @unknown_option_imports.each { |name| import_error(name, missing_import_message(name)) }
        end
        return if errors?
        # option types declared in this file are read from the draft itself,
        # linked and with its structural features
        @draft.resolve(@pool)
        @interpreter = OptionInterpreter.new(self, @pool, @options_fallback)
        options = @interpreter.run(@pending) { |features| check_features(features) }
        options.each { |node, value| @draft.set_options(descriptor_of(node), value) }
        @locations = SourceInfo.rewrite_option_paths(@ast.locations, @interpreter.interpreted_paths)
      rescue Schema::Error => e
        error(nil, nil, e.message)
      end

      FEATURE_UNKNOWNS = {
        field_presence: :FIELD_PRESENCE_UNKNOWN, enum_type: :ENUM_TYPE_UNKNOWN,
        repeated_field_encoding: :REPEATED_FIELD_ENCODING_UNKNOWN, utf8_validation: :UTF8_VALIDATION_UNKNOWN,
        message_encoding: :MESSAGE_ENCODING_UNKNOWN, json_format: :JSON_FORMAT_UNKNOWN,
        enforce_naming_style: :ENFORCE_NAMING_STYLE_UNKNOWN,
        default_symbol_visibility: :DEFAULT_SYMBOL_VISIBILITY_UNKNOWN, enforce_proto_limits: :PROTO_LIMITS_UNKNOWN
      }.freeze

      # ResolveFeaturesImpl's checks, in VisitDescriptors order, once the
      # non-extension options (`features` among them) are known
      # @param features [Hash{AST::Node => Schema::MessageValue}] the `features` each element sets
      def check_features(features)
        each_element do |node, kind|
          raw = features[node]
          next if raw.nil?
          location = (kind == :file) ? :editions : :name
          if legacy?
            error(node, location, "Features are only valid under editions.")
            next
          end
          FEATURE_UNKNOWNS.each do |name, unknown|
            next unless raw[name] == unknown
            error(node, location, "Feature field `#{name}` must resolve to a known value, found #{unknown}")
            break
          end
        end
      end

      def build_schema
        if @source_info
          @draft.source_info = @locations.map(&:to_schema)
        end
        @file = @draft.resolve(@pool).freeze!
      rescue Schema::Error => e
        error(nil, nil, e.message)
        @file = nil
      end

      # FieldDescriptor::DefaultValueAsString over the parsed default
      def default_text(field)
        text = field.default_value
        case field.type
        when :TYPE_FLOAT
          Compiler.simple_ftoa(parse_float_default(text))
        when :TYPE_DOUBLE
          Compiler.simple_dtoa(parse_float_default(text))
        else
          text
        end
      end

      def parse_float_default(text)
        case text
        when "inf" then Float::INFINITY
        when "-inf" then -Float::INFINITY
        when "nan", "-nan" then Float::NAN
        else Float(text)
        end
      end

      # absl::CUnescape, as far as validity goes
      def c_unescape(text)
        Schema::DefaultValue.unescape_bytes(text)
      rescue Schema::Error
        nil
      end
    end
  end
end
