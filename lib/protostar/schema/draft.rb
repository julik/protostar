# frozen_string_literal: true

module Protostar
  module Schema
    class File
      # Starts describing a file. The draft creates the real descriptors as it
      # goes; {Draft::File#resolve} links them and {Draft::File#freeze!} hands
      # back the finished, shareable file.
      #
      #   file = Schema::File.draft("shop.proto", package: "shop", syntax: :proto3)
      #   file.message("Item") do |m|
      #     m.field "name", 1, :string
      #     m.field "price_cents", 2, :int64, optional: true
      #     m.map "stock", 3, key: :string, value: :int32
      #   end
      #   file.resolve(pool)
      #   file.freeze!  # => #<Protostar::Schema::File shop.proto>
      #
      # @param name [String] the file name as imported
      # @param package [String, nil]
      # @param syntax [Symbol, nil] :proto2, :proto3 or :editions; nil is proto2, and
      #   unlike an explicit :proto2 leaves `syntax` out of the FileDescriptorProto, as protoc does
      # @param edition [Symbol, Integer, nil] e.g. :EDITION_2023; implies :editions
      # @param dependencies [Array<String>] imported file names
      # @param public_dependencies [Array<String, Integer>] names or indexes of `import public` files
      # @param weak_dependencies [Array<String, Integer>]
      # @param option_dependencies [Array<String>] `import option` file names
      # @param options [Hash, nil] the file's options
      # @return [Draft::File]
      def self.draft(name, package: nil, syntax: nil, edition: nil, dependencies: [], public_dependencies: [],
        weak_dependencies: [], option_dependencies: [], options: nil)
        Draft::File.new(name, package: package, syntax: syntax, edition: edition, dependencies: dependencies,
          public_dependencies: public_dependencies, weak_dependencies: weak_dependencies,
          option_dependencies: option_dependencies, options: options)
      end
    end

    # The construction stage of {Schema}: mutable handles that create
    # descriptors, then link, resolve and freeze them. Map entries, the
    # synthetic oneofs of proto3 `optional` fields, group fields and json
    # names are made here and nowhere else.
    module Draft
      SYNTAXES = {nil => :proto2, :proto2 => :proto2, :proto3 => :proto3, :editions => :editions}.freeze
      SCALARS = (Field::TYPES.values - %i[message enum group]).to_h { |t| [t, true] }.freeze
      TYPES = Field::TYPES.values.to_h { |t| [t, true] }.freeze
      LABELS = %i[optional required repeated].freeze

      # protoc's name for the entry message of a map field: the field name in
      # CamelCase plus "Entry"
      # @param field_name [String]
      # @return [String]
      def self.map_entry_name(field_name)
        out = +""
        cap_next = true
        field_name.to_s.each_char do |c|
          if c == "_"
            cap_next = true
          elsif cap_next
            out << (c.between?("a", "z") ? c.upcase : c)
            cap_next = false
          else
            out << c
          end
        end
        out << "Entry"
      end

      # The names protoc's parser gives the synthetic oneofs of proto3
      # `optional` fields: `_` and the field name, with `X` prepended until
      # nothing in the message has that name
      # @param field_names [Array<String>] the fields needing one, in order
      # @param taken [Array<String>] every field and oneof name of the message
      # @return [Array<String>]
      def self.synthetic_oneof_names(field_names, taken)
        names = taken.to_h { |n| [n, true] }
        field_names.map do |field_name|
          name = field_name.start_with?("_") ? field_name : "_#{field_name}"
          name = "X#{name}" while names.key?(name)
          names[name] = true
          name
        end
      end

      # The field a `group Name = n { ... }` declares: the group's name in lower case
      # @return [String]
      def self.group_field_name(group_name)
        group_name.to_s.downcase(:ascii)
      end

      # protoc's spelling of a default value
      # @api private
      def self.default_text(value)
        case value
        when nil, String then value
        when Symbol then value.to_s
        when Float then Compiler.simple_dtoa(value)
        else value.to_s
        end
      end

      VISIBILITIES = {
        nil => nil, :local => :local, :export => :export, :VISIBILITY_LOCAL => :local,
        :VISIBILITY_EXPORT => :export, :VISIBILITY_UNSET => nil
      }.freeze

      # :local or :export from either spelling; nil when unset
      # @api private
      def self.visibility(value)
        VISIBILITIES.fetch(value) { raise Error, "unknown visibility #{value.inspect}" }
      end

      # Inclusive bounds of an Integer or a Range
      # @api private
      def self.bounds(item)
        case item
        when Integer then [item, item]
        when ::Range
          last = item.exclude_end? ? item.end - 1 : item.end
          [item.begin, last]
        else raise Error, "expected an Integer or a Range, got #{item.inspect}"
        end
      end

      # What files and messages share: nested messages, enums and extensions
      class Scope
        # @api private
        attr_reader :file_draft

        # A message type
        # @param name [String]
        # @param visibility [Symbol, nil] :local or :export (edition 2024)
        # @param options [Hash, nil]
        # @yieldparam m [Message]
        # @return [Message]
        def message(name, visibility: nil, options: nil, &block)
          name = name.to_s
          descriptor = Schema::Message.new(name: name, full_name: qualify(name), file: @file_draft.descriptor,
            containing_message: containing_message, index: @messages.size)
          draft = Message.new(@file_draft, descriptor, Draft.visibility(visibility), options)
          @messages << draft
          @file_draft.register(descriptor)
          block&.call(draft)
          draft
        end

        # An enum type
        # @yieldparam e [Enum]
        # @return [Enum]
        def enum(name, visibility: nil, options: nil, &block)
          name = name.to_s
          descriptor = Schema::Enum.new(name: name, full_name: qualify(name), file: @file_draft.descriptor,
            containing_message: containing_message, index: @enums.size)
          draft = Enum.new(@file_draft, descriptor, scope_name, Draft.visibility(visibility), options)
          @enums << draft
          @file_draft.register(descriptor)
          block&.call(draft)
          draft
        end

        # Extensions of another message, declared in this scope
        # @param extendee [String] the extended message, as written
        # @yieldparam e [Extend]
        def extend(extendee, &block)
          block.call(Extend.new(self, extendee.to_s))
          self
        end

        # One extension field; the arguments of {Message#field} plus the extendee
        # @return [Schema::Field]
        def extension(name, number, type, type_name = nil, extendee:, label: :optional, default: nil, json_name: nil,
          optional: false, options: nil)
          field = @file_draft.new_field(self, name, number, type, type_name, @extensions.size, extendee.to_s, label,
            default, json_name, optional, options, nil)
          @extensions << field
          field
        end

        # @api private
        def qualify(name)
          scope = scope_name
          -(scope.empty? ? name : "#{scope}.#{name}")
        end

        def inspect
          "#<#{self.class.name} #{@descriptor.full_name}>"
        end
      end

      # A file under construction
      class File < Scope
        # @return [Schema::File] the file being built; frozen after {#freeze!}
        attr_reader :descriptor

        # @api private
        def initialize(name, package:, syntax:, edition:, dependencies:, public_dependencies:, weak_dependencies:,
          option_dependencies:, options:)
          @file_draft = self
          @messages = []
          @enums = []
          @extensions = []
          @services = []
          @fields = []
          @methods = []
          @duplicates = []
          @options = {}.compare_by_identity
          @dependencies = Array(dependencies).map { |d| -d.to_s }.freeze
          @public = indexes(name, public_dependencies)
          @weak = indexes(name, weak_dependencies)
          @option_dependencies = Array(option_dependencies).map { |d| -d.to_s }.freeze
          syntax, edition, proto_syntax = syntax_and_edition(name, syntax, edition)
          @descriptor = Schema::File.new(name: -name.to_s, package: -package.to_s, syntax: syntax, edition: edition,
            proto_syntax: proto_syntax)
          @options[@descriptor] = options
        end

        # @return [String]
        def scope_name
          @descriptor.package
        end

        # A service
        # @yieldparam s [Service]
        # @return [Service]
        def service(name, options: nil, &block)
          name = name.to_s
          descriptor = Schema::Service.new(name: name, full_name: qualify(name), file: @descriptor,
            index: @services.size)
          draft = Service.new(self, descriptor)
          @options[descriptor] = options
          @services << draft
          register(descriptor)
          block&.call(draft)
          draft
        end

        # @param info [SourceInfo, Array<SourceInfo::Location>, nil]
        def source_info=(info)
          info = SourceInfo.new(info) if info.is_a?(Array)
          @descriptor.__link(source_info: info)
        end

        # Sets (or replaces) the options of a descriptor of this file
        # @param descriptor [Descriptor]
        # @param options [Hash, nil]
        def set_options(descriptor, options)
          @options[descriptor] = options
        end

        # Finds dependencies in the pool, completes every message's lookup
        # tables and resolves every type name, extendee and method type. Runs
        # once; {#resolve} calls it when it has not run.
        # @param pool [Pool] where the dependencies are
        # @return [self]
        # @raise [Error, ResolveError]
        def link(pool)
          return self if @linked
          unless @duplicates.empty?
            first, second = @duplicates.first
            raise Error, "#{@descriptor.name}: \"#{first.full_name}\" is defined twice " \
              "(#{kind_name(first)} and #{kind_name(second)})"
          end
          files = @dependencies.map do |dep|
            pool.file(dep) || raise(Error, "#{@descriptor.name}: dependency \"#{dep}\" is not in the pool")
          end
          @descriptor.__dependencies(dependencies: @dependencies, public_dependencies: @public,
            weak_dependencies: @weak, option_dependencies: @option_dependencies, dependency_files: files.freeze)
          seal
          link_fields(pool)
          link_methods(pool)
          @linked = true
          self
        end

        # Links (when not done yet), then builds options, resolves features and
        # parses defaults. May run again after options change.
        # @param pool [Pool]
        # @return [self]
        def resolve(pool)
          link(pool)
          Resolution.new(@descriptor, @fields, @options, pool).call
          @resolved = true
          self
        end

        # Freezes the whole graph and makes it Ractor-shareable
        # @return [Schema::File]
        def freeze!
          raise Error, "#{@descriptor.name}: resolve the draft before freezing it" unless @resolved
          Freezer.deep_freeze(@descriptor)
          Ractor.make_shareable(@descriptor)
        end

        # Completes every message's, enum's and service's lookup tables once
        # nothing more will be added. {#link} does it; a caller that resolves
        # names itself (the compiler) calls it first.
        # @api private
        def __seal
          seal
          self
        end

        # Sets what a field's type name resolved to, for a caller that
        # resolves names itself; {#link} then leaves the field alone
        # @api private
        def __resolve_type(field, target)
          type = field.declared_type || (target.is_a?(Schema::Message) ? :message : :enum)
          kind = target.is_a?(Schema::Message) ? :message_type : :enum_type
          field.__link(kind => target, :type_name => target.full_name, :declared_type => type, :type => type)
        end

        # @api private
        def __resolve_extendee(field, target)
          field.__link(extendee: target)
        end

        # @api private
        def __resolve_rpc(method, input: nil, output: nil)
          method.__link(input_type: input) if input
          method.__link(output_type: output) if output
        end

        # @api private
        def register(descriptor)
          symbols = @descriptor.symbols
          if (existing = symbols[descriptor.full_name])
            @duplicates << [existing, descriptor]
          else
            symbols[descriptor.full_name] = descriptor
          end
        end

        # @api private
        def new_field(scope, name, number, type, type_name, index, extendee, label, default, json_name, optional, options,
          oneof)
          name = name.to_s
          raise Error, "#{@descriptor.name}: field #{name} needs an integer number" unless number.is_a?(Integer)
          label = (label || :optional).to_sym
          raise Error, "#{@descriptor.name}: unknown label #{label.inspect} for #{name}" unless LABELS.include?(label)
          if type.is_a?(String)
            raise Error, "#{@descriptor.name}: #{name} has two type names" if type_name
            type_name = type
            type = nil
          elsif !type.nil?
            type = type.to_sym
            raise Error, "#{@descriptor.name}: unknown field type #{type.inspect} for #{name}" unless TYPES.key?(type)
          end
          if type_name.nil? && !SCALARS.key?(type)
            raise Error, "#{@descriptor.name}: #{name} needs a type name"
          elsif type_name && SCALARS.key?(type)
            raise Error, "#{@descriptor.name}: #{name} is a #{type} and cannot have a type name"
          end
          message = scope.is_a?(Message) ? scope.descriptor : nil
          field = Field.new(
            name: name, full_name: scope.qualify(name), number: number, label: label, type: type,
            type_name: type_name && -type_name.to_s, extendee_name: extendee && -extendee, raw_default:
            Draft.default_text(default)&.then { |t| -t }, json_name: -(json_name&.to_s || Schema.json_name(name)),
            proto3_optional: optional ? true : false, extension: !extendee.nil?, containing_message: message,
            file: @descriptor, index: index
          )
          @options[field] = options
          @fields << [field, scope.scope_name]
          register(field)
          scope.__oneof_member(field, oneof) if extendee.nil? && (oneof || optional)
          field
        end

        # @api private
        def new_method(method, options)
          @options[method] = options
          @methods << method
          register(method)
        end

        private

        def kind_name(descriptor)
          descriptor.class.name.split("::").last
        end

        def indexes(name, list)
          deps = Array(@dependencies)
          list = Array(list).map do |dep|
            next dep if dep.is_a?(Integer) && dep >= 0 && dep < deps.size
            index = deps.index(dep.to_s)
            raise Error, "#{name}: #{dep.inspect} is not among the dependencies" unless index
            index
          end
          list.empty? ? Freezer::EMPTY_ARRAY : list.freeze
        end

        def syntax_and_edition(name, syntax, edition)
          syntax = syntax.to_sym if syntax.is_a?(String)
          raise Error, "#{name}: unknown syntax #{syntax.inspect}" unless SYNTAXES.key?(syntax)
          proto_syntax = syntax&.to_s
          if edition.is_a?(Integer)
            edition = Features::EDITION_NAMES.fetch(edition, edition)
          elsif edition
            edition = edition.to_sym
            raise Error, "#{name}: unknown edition #{edition.inspect}" unless Features::EDITIONS.key?(edition)
          end
          if edition && syntax.nil?
            syntax = :editions
            proto_syntax = "editions"
          end
          resolved = SYNTAXES.fetch(syntax)
          if resolved == :editions && edition.nil?
            raise Error, "#{name}: syntax \"editions\" needs an edition"
          elsif resolved != :editions && edition
            raise Error, "#{name}: syntax #{proto_syntax.inspect} cannot have an edition"
          end
          [resolved, edition, proto_syntax && -proto_syntax]
        end

        def containing_message
          nil
        end

        def seal
          return if @sealed
          @sealed = true
          messages = @messages.map { |m| m.__seal(@options) }.freeze
          enums = @enums.map { |e| e.__seal(@options) }.freeze
          services = @services.map(&:__seal).freeze
          extensions = @extensions.freeze
          all = []
          walk = lambda do |m|
            all << m
            m.nested_messages.each(&walk)
          end
          messages.each(&walk)
          @descriptor.__link(
            messages: messages, enums: enums, services: services, extensions: extensions,
            all_messages: all.freeze, all_enums: (enums + all.flat_map(&:nested_enums)).freeze,
            all_extensions: (extensions + all.flat_map(&:extensions)).freeze
          )
        end

        def link_fields(pool)
          @fields.each do |field, scope|
            attrs = {}
            if field.type_name && field.message_type.nil? && field.enum_type.nil?
              target = resolve_name(pool, field.type_name, scope, field)
              type = field.declared_type
              case target
              when Schema::Message
                type ||= :message
                unless type == :message || type == :group
                  raise ResolveError.new("#{@descriptor.name}: #{field.full_name}: \"#{field.type_name}\" is not an " \
                    "enum type", name: field.type_name, scope: scope)
                end
                attrs[:message_type] = target
              when Schema::Enum
                type ||= :enum
                unless type == :enum
                  raise ResolveError.new("#{@descriptor.name}: #{field.full_name}: \"#{field.type_name}\" is not a " \
                    "message type", name: field.type_name, scope: scope)
                end
                attrs[:enum_type] = target
              else
                raise ResolveError.new("#{@descriptor.name}: #{field.full_name}: \"#{field.type_name}\" is not a type",
                  name: field.type_name, scope: scope)
              end
              attrs.merge!(type_name: target.full_name, declared_type: type, type: type)
            end
            if field.extension? && field.extendee.nil?
              extendee = resolve_name(pool, field.extendee_name, scope, field)
              unless extendee.is_a?(Schema::Message)
                raise ResolveError.new("#{@descriptor.name}: #{field.full_name}: \"#{field.extendee_name}\" is not a " \
                  "message type", name: field.extendee_name, scope: scope)
              end
              attrs[:extendee] = extendee
            end
            field.__link(**attrs) unless attrs.empty?
          end
        end

        def link_methods(pool)
          @methods.each do |method|
            next if method.input_type && method.output_type
            scope = method.service.full_name
            input = resolve_name(pool, method.input_type_name, scope, method)
            output = resolve_name(pool, method.output_type_name, scope, method)
            [[method.input_type_name, input], [method.output_type_name, output]].each do |written, found|
              next if found.is_a?(Schema::Message)
              raise ResolveError.new("#{@descriptor.name}: #{method.full_name}: \"#{written}\" is not a message type",
                name: written, scope: scope)
            end
            method.__link(input_type: input, output_type: output)
          end
        end

        def resolve_name(pool, name, scope, element)
          Resolver.resolve(name, scope: scope, file: @descriptor, pool: pool)
        rescue ResolveError => e
          raise ResolveError.new("#{@descriptor.name}: #{element.full_name}: #{e.message}", name: e.name,
            scope: e.scope)
        end
      end

      # A message under construction: the block argument of {Scope#message}
      class Message < Scope
        # @return [Schema::Message]
        attr_reader :descriptor

        # @api private
        def initialize(file_draft, descriptor, visibility, options)
          @file_draft = file_draft
          @descriptor = descriptor
          @visibility = visibility
          @messages = []
          @enums = []
          @extensions = []
          @fields = []
          @oneofs = []
          @oneof_names = {}
          @synthetic = []
          @ranges = []
          @reserved_ranges = []
          @reserved_names = []
          file_draft.set_options(descriptor, options)
        end

        # @return [String]
        def scope_name
          @descriptor.full_name
        end

        # A field
        # @param name [String, Symbol]
        # @param number [Integer]
        # @param type [Symbol, String] :int32, :string, ... :message, :enum or :group (then
        #   give `type_name`), or a type name whose kind is found when linking
        # @param type_name [String, nil] the message or enum type as written, e.g. ".acme.Person"
        # @param label [Symbol] :optional, :required or :repeated
        # @param default [String, Object, nil] the default; text is taken as protoc stores it
        # @param json_name [String, nil] when not the one derived from the name
        # @param optional [Boolean] a proto3 `optional` field; its synthetic oneof is made here
        #   unless `oneof:` names one
        # @param oneof [String, Symbol, Schema::Oneof, nil] the oneof the field belongs to
        # @param options [Hash, nil]
        # @return [Schema::Field]
        def field(name, number, type, type_name = nil, label: :optional, default: nil, json_name: nil, optional: false,
          oneof: nil, options: nil)
          field = @file_draft.new_field(self, name, number, type, type_name, @fields.size, nil, label, default,
            json_name, optional, options, oneof)
          @fields << field
          field
        end

        # A `map<K, V>` field and the entry message protoc synthesizes for it
        # @param key [Symbol] the key type
        # @param value [Symbol, String] a scalar type, or the value's message or enum type name
        # @param value_type_name [String, nil] the type name when `value` is :message or :enum
        # @param options [Hash, nil] the field's options; its `features` go to the key and value too
        # @return [Schema::Field]
        def map(name, number, key:, value:, value_type_name: nil, json_name: nil, options: nil)
          name = name.to_s
          if value.is_a?(String)
            value_type_name = value
            value = nil
          end
          features = options && (options[:features] || options["features"])
          entry_options = features && {features: features}
          entry = message(Draft.map_entry_name(name), options: {map_entry: true})
          entry.field("key", 1, key, options: entry_options)
          entry.field("value", 2, value, value_type_name, options: entry_options)
          field(name, number, :message, ".#{entry.descriptor.full_name}", label: :repeated, json_name: json_name,
            options: options)
        end

        # A proto2 group: a nested message and a field of type group named after it
        # @param message_options [Hash, nil] the nested message's options
        # @yieldparam g [Message]
        # @return [Schema::Field]
        def group(name, number, label: :optional, json_name: nil, oneof: nil, options: nil, message_options: nil,
          &block)
          nested = message(name.to_s, options: message_options, &block)
          field(Draft.group_field_name(name), number, :group, ".#{nested.descriptor.full_name}", label: label,
            json_name: json_name, oneof: oneof, options: options)
        end

        # A oneof. Fields given in the block belong to it; fields elsewhere may
        # name it with `oneof:`. Declaring it again only sets its options.
        # @yieldparam o [Oneof]
        # @return [Schema::Oneof]
        def oneof(name, options: nil, &block)
          oneof = declare_oneof(name.to_s)
          @file_draft.set_options(oneof, options) if options
          block&.call(Oneof.new(self, oneof))
          oneof
        end

        # One extension range, inclusive
        # @param range [Range, Integer]
        # @return [Schema::ExtensionRange]
        def extension_range(range, options: nil)
          first, last = Draft.bounds(range)
          descriptor = Schema::ExtensionRange.new(containing_message: @descriptor, index: @ranges.size,
            range: first..last)
          @file_draft.set_options(descriptor, options)
          @ranges << descriptor
          descriptor
        end

        # Extension ranges, inclusive, sharing options
        # @param ranges [Array<Range, Integer>]
        def extensions(*ranges, options: nil)
          ranges.each { |r| extension_range(r, options: options) }
          self
        end

        # Reserved numbers (Integers or inclusive Ranges) and names (Strings or Symbols)
        def reserved(*items)
          items.each do |item|
            if item.is_a?(String) || item.is_a?(Symbol)
              @reserved_names << -item.to_s
            else
              first, last = Draft.bounds(item)
              @reserved_ranges << (first..last)
            end
          end
          self
        end

        # @api private
        def __oneof_member(field, oneof)
          if oneof.nil?
            @synthetic << field
            return
          end
          oneof = declare_oneof(oneof.to_s) unless oneof.is_a?(Schema::Oneof)
          oneof.fields << field
          field.__link(oneof: oneof)
        end

        # @api private
        def __seal(options)
          unless @synthetic.empty?
            taken = @fields.map(&:name) + @oneofs.map(&:name)
            names = Draft.synthetic_oneof_names(@synthetic.map(&:name), taken)
            @synthetic.zip(names) { |field, name| __oneof_member(field, declare_oneof(name)) }
            @synthetic = []
          end
          @oneofs.each do |oneof|
            members = oneof.fields.freeze
            oneof.__link(synthetic: members.size == 1 && members.first.proto3_optional?)
          end
          nested = @messages.map { |m| m.__seal(options) }.freeze
          enums = @enums.map { |e| e.__seal(options) }.freeze
          @descriptor.__link(reserved_ranges: frozen(@reserved_ranges), reserved_names: frozen(@reserved_names),
            visibility: @visibility)
          @descriptor.__members(fields: frozen(@fields), oneofs: frozen(@oneofs), nested_messages: nested,
            nested_enums: enums, extensions: frozen(@extensions), extension_range_descriptors: frozen(@ranges))
        end

        private

        def containing_message
          @descriptor
        end

        def declare_oneof(name)
          existing = @oneof_names[name]
          return existing if existing
          oneof = Schema::Oneof.new(name: -name, full_name: -"#{@descriptor.full_name}.#{name}",
            containing_message: @descriptor, index: @oneofs.size)
          @oneofs << oneof
          @oneof_names[name] = oneof
          @file_draft.set_options(oneof, nil)
          @file_draft.register(oneof)
          oneof
        end

        def frozen(list)
          list.empty? ? Freezer::EMPTY_ARRAY : list.dup.freeze
        end
      end

      # The block argument of {Message#oneof}
      class Oneof
        # @api private
        def initialize(message, oneof)
          @message = message
          @oneof = oneof
        end

        # A member field; the arguments of {Message#field}
        def field(name, number, type, type_name = nil, **kwargs)
          @message.field(name, number, type, type_name, oneof: @oneof, **kwargs)
        end

        # A member group; the arguments of {Message#group}
        def group(name, number, **kwargs, &block)
          @message.group(name, number, oneof: @oneof, **kwargs, &block)
        end
      end

      # The block argument of {Scope#extend}
      class Extend
        # @api private
        def initialize(scope, extendee)
          @scope = scope
          @extendee = extendee
        end

        # An extension field; the arguments of {Message#field}
        # @return [Schema::Field]
        def field(name, number, type, type_name = nil, **kwargs)
          @scope.extension(name, number, type, type_name, extendee: @extendee, **kwargs)
        end
      end

      # An enum under construction: the block argument of {Scope#enum}
      class Enum
        def inspect
          "#<#{self.class.name} #{@descriptor.full_name}>"
        end

        # @return [Schema::Enum]
        attr_reader :descriptor

        # @api private
        def initialize(file_draft, descriptor, scope, visibility, options)
          @file_draft = file_draft
          @descriptor = descriptor
          @scope = scope
          @visibility = visibility
          @values = []
          @reserved_ranges = []
          @reserved_names = []
          file_draft.set_options(descriptor, options)
        end

        # A value. Its full name is a sibling of the enum's, as in C++.
        # @return [Schema::EnumValue]
        def value(name, number, options: nil)
          name = name.to_s
          raise Error, "#{@descriptor.full_name}: value #{name} needs an integer number" unless number.is_a?(Integer)
          value = EnumValue.new(name: -name, full_name: -(@scope.empty? ? name : "#{@scope}.#{name}"),
            number: number, enum: @descriptor, index: @values.size)
          @file_draft.set_options(value, options)
          @file_draft.register(value)
          @values << value
          value
        end

        # Reserved numbers (Integers or inclusive Ranges) and names
        def reserved(*items)
          items.each do |item|
            if item.is_a?(String) || item.is_a?(Symbol)
              @reserved_names << -item.to_s
            else
              first, last = Draft.bounds(item)
              @reserved_ranges << (first..last)
            end
          end
          self
        end

        # @api private
        def __seal(_options)
          @descriptor.__link(
            reserved_ranges: @reserved_ranges.empty? ? Freezer::EMPTY_ARRAY : @reserved_ranges.dup.freeze,
            reserved_names: @reserved_names.empty? ? Freezer::EMPTY_ARRAY : @reserved_names.dup.freeze,
            visibility: @visibility
          )
          @descriptor.__values(@values.empty? ? Freezer::EMPTY_ARRAY : @values.dup.freeze)
        end
      end

      # A service under construction: the block argument of {File#service}
      class Service
        def inspect
          "#<#{self.class.name} #{@descriptor.full_name}>"
        end

        # @return [Schema::Service]
        attr_reader :descriptor

        # @api private
        def initialize(file_draft, descriptor)
          @file_draft = file_draft
          @descriptor = descriptor
          @rpcs = []
        end

        # @param name [String, Symbol]
        # @param input_type [String] as written, e.g. ".acme.Request"
        # @param output_type [String]
        # @return [Schema::Method]
        def rpc(name, input_type, output_type, client_streaming: false, server_streaming: false, options: nil)
          name = name.to_s
          method = Schema::Method.new(name: -name, full_name: -"#{@descriptor.full_name}.#{name}",
            service: @descriptor, index: @rpcs.size, input_type_name: -input_type.to_s,
            output_type_name: -output_type.to_s, client_streaming: client_streaming ? true : false,
            server_streaming: server_streaming ? true : false)
          @file_draft.new_method(method, options)
          @rpcs << method
          method
        end

        # @api private
        def __seal
          @descriptor.__rpcs(@rpcs.empty? ? Freezer::EMPTY_ARRAY : @rpcs.dup.freeze)
        end
      end
    end
  end
end
