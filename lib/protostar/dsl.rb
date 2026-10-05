# frozen_string_literal: true

module Protostar
  # The runtime of generated `_pb.rb` files, also meant to be written by hand.
  # A block describes one `.proto` file; it is turned into the descriptor hash
  # protoc would produce, built into {Protostar.generated_pool} and its message
  # classes and enum modules are defined.
  #
  #   Protostar::DSL.file("acme/person.proto", package: "acme", syntax: :proto3) do |f|
  #     f.message "Person" do |m|
  #       m.field :name, 1, :string
  #       m.field :friends, 2, :message, ".acme.Person", label: :repeated
  #       m.oneof :contact do |o|
  #         o.field :email, 3, :string
  #       end
  #       m.map :attrs, 4, :string, :string
  #     end
  #   end
  #   module Acme
  #     Person = Protostar::DSL.message("acme.Person")
  #   end
  #
  # Every descriptor-level call takes the options of its descriptor as extra
  # keywords: `deprecated: true`, `packed: false`, `features: {...}`, with
  # custom options by extension full name under `extensions:`. An
  # `options:` Hash is taken verbatim as the options hash instead (with
  # `:__extensions` and `:__unknown_fields` spelled out), and is how an empty
  # options message is written.
  module DSL
    # Raised for a call the DSL cannot turn into a descriptor
    class Error < Protostar::Error; end

    SYNTAXES = {proto2: "proto2", proto3: "proto3", editions: "editions"}.freeze
    LABELS = {optional: :LABEL_OPTIONAL, required: :LABEL_REQUIRED, repeated: :LABEL_REPEATED}.freeze
    TYPES = Schema::Field::TYPES.invert.freeze

    class << self
      # Describes, builds and defines one `.proto` file. Loading a file the pool
      # already has is a no-op that returns the file there.
      #
      # @param name [String] the file name as imported, e.g. "acme/person.proto"
      # @param package [String, nil]
      # @param syntax [Symbol, String, nil] :proto2, :proto3 or :editions; omitted for proto2 as protoc does
      # @param edition [Symbol, Integer, nil] e.g. :EDITION_2023 or 2023; implies `syntax: :editions`
      # @param dependencies [Array<String>] imported file names, which must be loaded already
      # @param public_dependencies [Array<String, Integer>] names (or indexes) of `import public` files
      # @param weak_dependencies [Array<String, Integer>]
      # @param option_dependencies [Array<String>] `import option` file names
      # @param options [Hash, nil] the FileOptions hash verbatim
      # @param pool [Schema::Pool] where the file is built and added
      # @param registry [Types::Registry, nil] where classes are defined; nil builds the file only
      # @param file_options [Hash] FileOptions fields as keywords, custom ones under `extensions:`
      # @yieldparam f [FileBuilder]
      # @return [Schema::File]
      def file(name, package: nil, syntax: nil, edition: nil, dependencies: nil, public_dependencies: nil,
        weak_dependencies: nil, option_dependencies: nil, options: nil, pool: Protostar.generated_pool,
        registry: Types.registry, **file_options, &block)
        existing = pool.file(name)
        return existing if existing
        builder = FileBuilder.new(name, package: package, syntax: syntax, edition: edition,
          dependencies: dependencies, public_dependencies: public_dependencies, weak_dependencies: weak_dependencies,
          option_dependencies: option_dependencies, options: DSL.options(options, file_options))
        block&.call(builder)
        built = Schema::Builder.build(builder.to_h, pool: pool)
        pool.add(built)
        registry&.define(built)
        built
      end

      # Describes a file and returns its descriptor hash without building it
      # @return [Hash] a FileDescriptorProto hash
      def file_hash(name, package: nil, syntax: nil, edition: nil, dependencies: nil, public_dependencies: nil,
        weak_dependencies: nil, option_dependencies: nil, options: nil, **file_options, &block)
        builder = FileBuilder.new(name, package: package, syntax: syntax, edition: edition,
          dependencies: dependencies, public_dependencies: public_dependencies, weak_dependencies: weak_dependencies,
          option_dependencies: option_dependencies, options: DSL.options(options, file_options))
        block&.call(builder)
        builder.to_h
      end

      # @param full_name [String] e.g. "acme.Person"
      # @return [Class] the message class defined for it
      # @raise [Error] when no file defined it
      def message(full_name, registry: Types.registry)
        found = registry.find(full_name)
        raise Error, "no message #{full_name} has been defined" unless found.is_a?(Class)
        found
      end

      # @param full_name [String]
      # @return [Module] the enum module defined for it
      def enum(full_name, registry: Types.registry)
        found = registry.find(full_name)
        raise Error, "no enum #{full_name} has been defined" unless found.is_a?(Module) && !found.is_a?(Class)
        found
      end

      # A Module standing for a service, which gRPC stubs reopen to add
      # `Service` and `Stub`
      # @param full_name [String]
      # @return [Module] answering `descriptor` with the {Schema::Service}
      def service(full_name, pool: Protostar.generated_pool)
        descriptor = pool.find_service(full_name) || raise(Error, "no service #{full_name} has been defined")
        mod = Module.new
        mod.instance_variable_set(:@descriptor, descriptor)
        mod.extend(ServiceModule)
        mod
      end

      # Merges keyword options into a verbatim options hash
      # @api private
      def options(verbatim, keywords)
        return verbatim if keywords.empty?
        out = verbatim ? verbatim.dup : {}
        keywords.each do |key, value|
          if key == :extensions
            out[:__extensions] = (out[:__extensions] || {}).merge(value)
          else
            out[key] = value
          end
        end
        out
      end

      # protoc's name for the entry message of a map field
      # @param field_name [String]
      # @return [String]
      def map_entry_name(field_name)
        Schema::Draft.map_entry_name(field_name)
      end

      # The entry message protoc's parser synthesizes for a map field. The
      # field's `features` are copied onto key and value, as protoc does.
      # @api private
      def map_entry_hash(field_name, key_type, value_type, value_type_name, field_options)
        features = field_options && field_options[:features]
        key = {name: "key", number: 1, label: :LABEL_OPTIONAL, type: type_enum(key_type), json_name: "key"}
        value = {name: "value", number: 2, label: :LABEL_OPTIONAL, json_name: "value"}
        value[:type] = type_enum(value_type) if value_type
        value[:type_name] = value_type_name if value_type_name
        if features
          key[:options] = {features: features}
          value[:options] = {features: features}
        end
        {name: map_entry_name(field_name), field: [key, value], options: {map_entry: true}}
      end

      # @api private
      def type_enum(type)
        return type if Schema::Field::TYPES.key?(type)
        TYPES.fetch(type.to_sym) { raise Error, "unknown field type #{type.inspect}" }
      end

      # @api private
      def label_enum(label)
        return :LABEL_OPTIONAL if label.nil?
        return label if Schema::Field::LABELS.key?(label)
        LABELS.fetch(label.to_sym) { raise Error, "unknown label #{label.inspect}" }
      end
    end

    # Extended by the Modules {DSL.service} returns
    module ServiceModule
      # @return [Schema::Service]
      attr_reader :descriptor
    end

    # Common to every scope that holds fields, messages, enums and extensions
    # @api private
    class Scope
      def initialize(full_name)
        @full_name = full_name
        @messages = []
        @enums = []
        @extensions = []
      end

      # A nested (or top-level) message
      # @param name [String]
      # @param visibility [Symbol, nil] :VISIBILITY_LOCAL or :VISIBILITY_EXPORT (edition 2024)
      # @param options [Hash, nil] MessageOptions verbatim
      # @yieldparam m [MessageBuilder]
      def message(name, visibility: nil, options: nil, **message_options, &block)
        builder = MessageBuilder.new(name.to_s, qualify(name), visibility, DSL.options(options, message_options))
        @messages << builder
        block&.call(builder)
        builder
      end

      # An enum
      # @yieldparam e [EnumBuilder]
      def enum(name, visibility: nil, options: nil, **enum_options, &block)
        builder = EnumBuilder.new(name.to_s, visibility, DSL.options(options, enum_options))
        @enums << builder
        block&.call(builder)
        builder
      end

      # Extensions of another message declared in this scope
      # @param extendee [String] the extended message, e.g. ".acme.Base"
      # @yieldparam e [ExtendBuilder]
      def extend(extendee, &block)
        block.call(ExtendBuilder.new(self, extendee.to_s))
        self
      end

      # @api private
      def __add_extension(hash)
        @extensions << hash
      end

      private

      def qualify(name)
        @full_name.empty? ? name.to_s : "#{@full_name}.#{name}"
      end
    end

    # The block argument of {DSL.file}
    class FileBuilder < Scope
      # @api private
      def initialize(name, package:, syntax:, edition:, dependencies:, public_dependencies:, weak_dependencies:,
        option_dependencies:, options:)
        super(package.to_s)
        @name = name
        @package = package
        @syntax = syntax
        @edition = edition
        @dependencies = Array(dependencies)
        @public = Array(public_dependencies)
        @weak = Array(weak_dependencies)
        @option_dependencies = Array(option_dependencies)
        @options = options
        @services = []
      end

      # @param name [String]
      # @yieldparam s [ServiceBuilder]
      def service(name, options: nil, **service_options, &block)
        builder = ServiceBuilder.new(name.to_s, DSL.options(options, service_options))
        @services << builder
        block&.call(builder)
        builder
      end

      # @return [Hash] the FileDescriptorProto hash
      def to_h
        h = {name: @name}
        h[:package] = @package.to_s if @package && !@package.to_s.empty?
        h[:dependency] = @dependencies.map(&:to_s) unless @dependencies.empty?
        h[:public_dependency] = indexes(@public) unless @public.empty?
        h[:weak_dependency] = indexes(@weak) unless @weak.empty?
        h[:option_dependency] = @option_dependencies.map(&:to_s) unless @option_dependencies.empty?
        h[:message_type] = @messages.map(&:to_h) unless @messages.empty?
        h[:enum_type] = @enums.map(&:to_h) unless @enums.empty?
        h[:service] = @services.map(&:to_h) unless @services.empty?
        h[:extension] = @extensions unless @extensions.empty?
        h[:options] = @options if @options
        syntax, edition = syntax_and_edition
        h[:syntax] = syntax if syntax
        h[:edition] = edition if edition
        h
      end

      private

      def indexes(list)
        list.map do |dep|
          next dep if dep.is_a?(Integer)
          @dependencies.index(dep.to_s) || raise(Error, "#{@name}: #{dep.inspect} is not among the dependencies")
        end
      end

      def syntax_and_edition
        edition = @edition
        if edition.is_a?(Integer) && !Schema::Features::EDITION_NAMES.key?(edition)
          edition = :"EDITION_#{edition}"
        elsif edition.is_a?(Integer)
          edition = Schema::Features::EDITION_NAMES.fetch(edition)
        end
        edition = edition.to_sym if edition.is_a?(String)
        syntax = @syntax
        syntax = SYNTAXES.fetch(syntax) { raise Error, "#{@name}: unknown syntax #{syntax.inspect}" } if syntax.is_a?(Symbol)
        syntax = "editions" if edition && syntax.nil?
        [syntax, edition]
      end
    end

    # The block argument of {Scope#message}
    class MessageBuilder < Scope
      # @api private
      def initialize(name, full_name, visibility, options)
        super(full_name)
        @name = name
        @visibility = visibility
        @options = options
        @fields = []
        @oneofs = []
        @oneof_names = {}
        @ranges = []
        @reserved_ranges = []
        @reserved_names = []
      end

      # A field
      # @param name [Symbol, String]
      # @param number [Integer]
      # @param type [Symbol, String] :int32, :string, :message, :enum, :group, ...; a String is taken as
      #   the type name of a message or enum, its kind looked up when the file is built
      # @param type_name [String, nil] the message or enum type, e.g. ".acme.Person"
      # @param label [Symbol, nil] :optional (the default), :required or :repeated
      # @param default [Object, nil] the default as protoc stores it: text, C-escaped for bytes
      # @param json_name [String, nil] when not the one derived from the name
      # @param proto3_optional [Boolean] a proto3 `optional` field; its synthetic oneof is made for it
      # @param oneof [Symbol, String, nil] the oneof the field belongs to
      # @param options [Hash, nil] FieldOptions verbatim
      def field(name, number, type, type_name = nil, label: nil, default: nil, json_name: nil, proto3_optional: nil,
        oneof: nil, options: nil, **field_options)
        h = DSL.field_hash(name, number, type, type_name, label, default, json_name, proto3_optional,
          DSL.options(options, field_options))
        h[:oneof_index] = oneof_index(oneof) if oneof
        @fields << h
        h
      end

      # A `map<K, V>` field and its synthesized entry message
      # @param key_type [Symbol]
      # @param value_type [Symbol, String] a scalar type, :message or :enum (then give `value_type_name`),
      #   or the value's type name
      def map(name, number, key_type, value_type, value_type_name = nil, json_name: nil, options: nil, **field_options)
        if value_type.is_a?(String)
          value_type_name = value_type
          value_type = nil
        end
        field_opts = DSL.options(options, field_options)
        entry = DSL.map_entry_hash(name.to_s, key_type, value_type, value_type_name, field_opts)
        @messages << entry
        h = {name: name.to_s, number: number, label: :LABEL_REPEATED, type: :TYPE_MESSAGE,
             type_name: ".#{qualify(entry[:name])}"}
        h[:json_name] = json_name if json_name
        h[:options] = field_opts if field_opts
        @fields << h
        h
      end

      # A proto2 group: a field of type group and its nested message, named as
      # in `group Name = number { ... }`
      # @yieldparam g [MessageBuilder]
      def group(name, number, label: nil, json_name: nil, oneof: nil, options: nil, message_options: nil,
        **field_options, &block)
        nested = message(name.to_s, options: message_options, &block)
        field(name.to_s.downcase, number, :group, ".#{qualify(name)}", label: label, json_name: json_name,
          oneof: oneof, options: options, **field_options)
        nested
      end

      # A oneof. Fields given in the block belong to it; fields elsewhere may
      # name it with `oneof:`.
      # @yieldparam o [OneofBuilder]
      def oneof(name, options: nil, **oneof_options, &block)
        index = declare_oneof(name, DSL.options(options, oneof_options))
        block&.call(OneofBuilder.new(self, name))
        @oneofs[index]
      end

      # Extension ranges, inclusive
      # @param ranges [Array<Range, Integer>]
      def extensions(*ranges, options: nil, **range_options)
        opts = DSL.options(options, range_options)
        ranges.each do |r|
          first, last = DSL.bounds(r)
          h = {start: first, end: last + 1}
          h[:options] = opts if opts
          @ranges << h
        end
        self
      end

      # Reserved numbers (Integers or inclusive Ranges) and names (Strings)
      def reserved(*items)
        items.each do |item|
          if item.is_a?(String) || item.is_a?(Symbol)
            @reserved_names << item.to_s
          else
            first, last = DSL.bounds(item)
            @reserved_ranges << {start: first, end: last + 1}
          end
        end
        self
      end

      # @return [Hash] the DescriptorProto hash
      def to_h
        add_synthetic_oneofs
        h = {name: @name}
        h[:field] = @fields unless @fields.empty?
        h[:extension] = @extensions unless @extensions.empty?
        h[:nested_type] = @messages.map(&:to_h) unless @messages.empty?
        h[:enum_type] = @enums.map(&:to_h) unless @enums.empty?
        h[:extension_range] = @ranges unless @ranges.empty?
        h[:options] = @options if @options
        h[:oneof_decl] = @oneofs unless @oneofs.empty?
        h[:reserved_range] = @reserved_ranges unless @reserved_ranges.empty?
        h[:reserved_name] = @reserved_names unless @reserved_names.empty?
        h[:visibility] = @visibility if @visibility
        h
      end

      private

      def declare_oneof(name, options)
        key = name.to_s
        index = @oneof_names[key]
        if index
          @oneofs[index][:options] = options if options
          return index
        end
        h = {name: key}
        h[:options] = options if options
        @oneof_names[key] = @oneofs.size
        @oneofs << h
        @oneofs.size - 1
      end

      def oneof_index(name)
        @oneof_names[name.to_s] || declare_oneof(name, nil)
      end

      # protoc's GenerateSyntheticOneofs, for proto3 `optional` fields not given a oneof
      def add_synthetic_oneofs
        pending = @fields.select { |f| f[:proto3_optional] && !f.key?(:oneof_index) }
        return if pending.empty?
        names = {}
        @fields.each { |f| names[f[:name]] = true }
        @oneofs.each { |o| names[o[:name]] = true }
        pending.each do |f|
          name = f[:name]
          name = "_#{name}" unless name.start_with?("_")
          name = "X#{name}" while names.key?(name)
          names[name] = true
          f[:oneof_index] = @oneofs.size
          @oneof_names[name] = @oneofs.size
          @oneofs << {name: name}
        end
      end
    end

    # The block argument of {MessageBuilder#oneof}
    class OneofBuilder
      # @api private
      def initialize(message, name)
        @message = message
        @name = name
      end

      # A member field; same arguments as {MessageBuilder#field}
      def field(name, number, type, type_name = nil, **kwargs)
        @message.field(name, number, type, type_name, oneof: @name, **kwargs)
      end

      # A member group; same arguments as {MessageBuilder#group}
      def group(name, number, **kwargs, &block)
        @message.group(name, number, oneof: @name, **kwargs, &block)
      end
    end

    # The block argument of {Scope#extend}
    class ExtendBuilder
      # @api private
      def initialize(scope, extendee)
        @scope = scope
        @extendee = extendee
      end

      # An extension field; same arguments as {MessageBuilder#field}
      def field(name, number, type, type_name = nil, label: nil, default: nil, json_name: nil, proto3_optional: nil,
        options: nil, **field_options)
        h = DSL.field_hash(name, number, type, type_name, label, default, json_name, proto3_optional,
          DSL.options(options, field_options))
        h[:extendee] = @extendee
        @scope.__add_extension(h)
        h
      end
    end

    # The block argument of {Scope#enum}
    class EnumBuilder
      # @api private
      def initialize(name, visibility, options)
        @name = name
        @visibility = visibility
        @options = options
        @values = []
        @reserved_ranges = []
        @reserved_names = []
      end

      # @param name [Symbol, String]
      # @param number [Integer]
      def value(name, number, options: nil, **value_options)
        h = {name: name.to_s, number: number}
        opts = DSL.options(options, value_options)
        h[:options] = opts if opts
        @values << h
        self
      end

      # Reserved numbers (Integers or inclusive Ranges) and names (Strings)
      def reserved(*items)
        items.each do |item|
          if item.is_a?(String) || item.is_a?(Symbol)
            @reserved_names << item.to_s
          else
            first, last = DSL.bounds(item)
            @reserved_ranges << {start: first, end: last}
          end
        end
        self
      end

      # @return [Hash] the EnumDescriptorProto hash
      def to_h
        h = {name: @name}
        h[:value] = @values unless @values.empty?
        h[:options] = @options if @options
        h[:reserved_range] = @reserved_ranges unless @reserved_ranges.empty?
        h[:reserved_name] = @reserved_names unless @reserved_names.empty?
        h[:visibility] = @visibility if @visibility
        h
      end
    end

    # The block argument of {FileBuilder#service}
    class ServiceBuilder
      # @api private
      def initialize(name, options)
        @name = name
        @options = options
        @methods = []
      end

      # @param name [Symbol, String]
      # @param input_type [String] e.g. ".acme.Request"
      # @param output_type [String]
      def rpc(name, input_type, output_type, client_streaming: false, server_streaming: false, options: nil,
        **method_options)
        h = {name: name.to_s, input_type: input_type.to_s, output_type: output_type.to_s}
        opts = DSL.options(options, method_options)
        h[:options] = opts if opts
        h[:client_streaming] = true if client_streaming
        h[:server_streaming] = true if server_streaming
        @methods << h
        self
      end

      # @return [Hash] the ServiceDescriptorProto hash
      def to_h
        h = {name: @name}
        h[:method] = @methods unless @methods.empty?
        h[:options] = @options if @options
        h
      end
    end

    class << self
      # @api private
      def field_hash(name, number, type, type_name, label, default, json_name, proto3_optional, options)
        h = {name: name.to_s, number: number, label: label_enum(label)}
        if type.is_a?(String)
          type_name = type
        else
          h[:type] = type_enum(type)
        end
        h[:type_name] = type_name.to_s if type_name
        h[:default_value] = default_text(default) unless default.nil?
        h[:json_name] = json_name.to_s if json_name
        h[:options] = options if options
        h[:proto3_optional] = true if proto3_optional
        h
      end

      # @api private
      def default_text(value)
        case value
        when String then value
        when Symbol then value.to_s
        when Float then Compiler.simple_dtoa(value)
        else value.to_s
        end
      end

      # @api private
      def bounds(item)
        case item
        when Integer then [item, item]
        when Range
          last = item.exclude_end? ? item.end - 1 : item.end
          [item.begin, last]
        else raise Error, "expected an Integer or a Range, got #{item.inspect}"
        end
      end
    end
  end
end
