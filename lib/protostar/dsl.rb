# frozen_string_literal: true

module Protostar
  # The runtime of generated `_pb.rb` files, also meant to be written by hand.
  # A block describes one `.proto` file through Schema::File.draft; the
  # file is resolved and frozen into Protostar.generated_pool, and its
  # message classes and enum modules are defined.
  #
  # ```ruby
  # Protostar::DSL.file("acme/person.proto", package: "acme", syntax: :proto3) do |f|
  #   f.message "Person" do |m|
  #     m.field :name, 1, :string
  #     m.field :friends, 2, :message, ".acme.Person", label: :repeated
  #     m.oneof :contact do |o|
  #       o.field :email, 3, :string
  #     end
  #     m.map :attrs, 4, :string, :string
  #   end
  # end
  # module Acme
  #   Person = Protostar::DSL.message("acme.Person")
  # end
  # ```
  #
  # Every descriptor-level call takes the options of its descriptor as extra
  # keywords: `deprecated: true`, `packed: false`, `features: {...}`, with
  # custom options by extension full name under `extensions:` and fields
  # nobody could interpret as wire bytes under `unknown_fields:`. An
  # `options:` Hash is taken as the options message verbatim instead, in the
  # same spelling, and is how an empty options message is written. Option
  # values that are messages are Hashes in that spelling too; a field of
  # such a message that is itself named `extensions` or `unknown_fields` is
  # given with a String key.
  #
  # The earlier spellings, `__extensions:`, `__unknown_fields:` (as
  # `[number, wire_type, bytes]` triples) and `visibility: :VISIBILITY_EXPORT`,
  # are still read until 0.2.0, with a deprecation warning.
  module DSL
    # Raised for a call the DSL cannot turn into a descriptor
    class Error < Protostar::Error; end

    SYNTAXES = {proto2: :proto2, proto3: :proto3, editions: :editions}.freeze
    LABELS = %i[optional required repeated].freeze
    OLD_VISIBILITIES = {VISIBILITY_LOCAL: :local, VISIBILITY_EXPORT: :export}.freeze

    class << self
      # Describes, builds and defines one `.proto` file. Loading a file the pool
      # already has is a no-op that returns the file there.
      #
      # - `name`: the file name as imported, e.g. "acme/person.proto"
      # - `syntax`: :proto2, :proto3 or :editions; omitted for proto2 as protoc does
      # - `edition`: e.g. :EDITION_2023 or 2023; implies `syntax: :editions`
      # - `dependencies`: imported file names, which must be loaded already
      # - `public_dependencies`: names (or indexes) of `import public` files
      # - `option_dependencies`: `import option` file names
      # - `options`: the FileOptions verbatim
      # - `pool`: where the file is built and added
      # - `registry`: where classes are defined; nil builds the file only
      # - `file_options`: FileOptions fields as keywords, custom ones under `extensions:`
      #: (String name, ?package: String?, ?syntax: (Symbol | String)?, ?edition: (Symbol | Integer)?, ?dependencies: Array[String], ?public_dependencies: Array[(String | Integer)], ?weak_dependencies: Array[(String | Integer)], ?option_dependencies: Array[String], ?options: Hash[untyped, untyped]?, ?pool: Schema::Pool, ?registry: Types::Registry?, **untyped file_options) ?{ (FileBuilder f) -> untyped } -> Schema::File
      def file(name, package: nil, syntax: nil, edition: nil, dependencies: nil, public_dependencies: nil,
        weak_dependencies: nil, option_dependencies: nil, options: nil, pool: Protostar.generated_pool,
        registry: Types.registry, **file_options, &block)
        existing = pool.file(name)
        return existing if existing
        draft = begin
          Schema::File.draft(name, package: package, syntax: syntax(name, syntax), edition: edition(edition),
            dependencies: Array(dependencies), public_dependencies: Array(public_dependencies),
            weak_dependencies: Array(weak_dependencies), option_dependencies: Array(option_dependencies),
            options: DSL.options(options, file_options))
        rescue Schema::Error => e
          raise Error, e.message
        end
        block&.call(FileBuilder.new(draft))
        built = draft.resolve(pool).freeze!
        pool.add(built)
        registry&.define(built)
        built
      end

      # - `full_name`: e.g. "acme.Person"
      #
      # Returns the message class defined for it.
      # Raises Error when no file defined it.
      #: (String full_name, ?registry: untyped) -> Class
      def message(full_name, registry: Types.registry)
        found = registry.find(full_name)
        raise Error, "no message #{full_name} has been defined" unless found.is_a?(Class)
        found
      end

      # Returns the enum module defined for it.
      #: (String full_name, ?registry: untyped) -> Module
      def enum(full_name, registry: Types.registry)
        found = registry.find(full_name)
        raise Error, "no enum #{full_name} has been defined" unless found.is_a?(Module) && !found.is_a?(Class)
        found
      end

      # A Module standing for a service, which gRPC stubs reopen to add
      # `Service` and `Stub`
      #
      # Returns answering `descriptor` with the Schema::Service.
      #: (String full_name, ?pool: untyped) -> Module
      def service(full_name, pool: Protostar.generated_pool)
        descriptor = pool.find_service(full_name) || raise(Error, "no service #{full_name} has been defined")
        mod = Module.new
        mod.instance_variable_set(:@descriptor, descriptor)
        mod.extend(ServiceModule)
        mod
      end

      # Options given as keywords merged into a verbatim options Hash
      def options(verbatim, keywords) # :nodoc:
        return verbatim if keywords.empty?
        out = verbatim ? verbatim.dup : {}
        keywords.each do |key, value|
          if key == :extensions
            out[:extensions] = (out[:extensions] || {}).merge(value)
          else
            out[key] = value
          end
        end
        out
      end

      # :local or :export; the deprecated protoc spellings are read with a warning
      def visibility(value) # :nodoc:
        replacement = OLD_VISIBILITIES[value]
        return value unless replacement
        Protostar.deprecated("visibility: #{value.inspect}", "visibility: #{replacement.inspect}")
        replacement
      end

      # protoc's name for the entry message of a map field
      #: (String field_name) -> String
      def map_entry_name(field_name)
        Schema::Draft.map_entry_name(field_name)
      end

      # A field type as the draft spells it: a short type Symbol, or a type name
      def type(type) # :nodoc:
        return type if type.is_a?(String)
        type = type.to_sym
        type = Schema::Field::TYPES.fetch(type, type)
        raise Error, "unknown field type #{type.inspect}" unless Schema::Field::TYPES.value?(type)
        type
      end

      def label(label) # :nodoc:
        return :optional if label.nil?
        label = label.to_sym
        label = Schema::Field::LABELS.fetch(label, label)
        raise Error, "unknown label #{label.inspect}" unless LABELS.include?(label)
        label
      end

      private

      def syntax(name, syntax)
        return nil if syntax.nil?
        SYNTAXES.fetch(syntax.to_sym) { raise Error, "#{name}: unknown syntax #{syntax.inspect}" }
      end

      def edition(edition)
        return edition unless edition.is_a?(Integer)
        Schema::Features::EDITION_NAMES.fetch(edition) { :"EDITION_#{edition}" }
      end
    end

    # Extended by the Modules DSL.service returns
    module ServiceModule
      attr_reader :descriptor #: Schema::Service
    end

    # Common to every scope that holds messages, enums and extensions
    class Scope # :nodoc: all
      def initialize(draft)
        @draft = draft
      end

      # A nested (or top-level) message
      #
      # - `visibility`: :local or :export (edition 2024)
      # - `options`: MessageOptions verbatim
      #: (String name, ?visibility: Symbol?, ?options: Hash[untyped, untyped]?, **untyped message_options) ?{ (MessageBuilder m) -> untyped } -> untyped
      def message(name, visibility: nil, options: nil, **message_options, &block)
        visibility = DSL.visibility(visibility)
        @draft.message(name, visibility: visibility, options: DSL.options(options, message_options)) do |m|
          block&.call(MessageBuilder.new(m))
        end
      end

      # An enum
      #: (untyped name, ?visibility: untyped, ?options: untyped, **untyped enum_options) ?{ (EnumBuilder e) -> untyped } -> untyped
      def enum(name, visibility: nil, options: nil, **enum_options, &block)
        visibility = DSL.visibility(visibility)
        @draft.enum(name, visibility: visibility, options: DSL.options(options, enum_options)) do |e|
          block&.call(EnumBuilder.new(e))
        end
      end

      # Extensions of another message declared in this scope
      #
      # - `extendee`: the extended message, e.g. ".acme.Base"
      #: (String extendee) ?{ (ExtendBuilder e) -> untyped } -> untyped
      def extend(extendee, &block)
        block.call(ExtendBuilder.new(@draft, extendee.to_s))
        self
      end
    end

    # The block argument of DSL.file
    class FileBuilder < Scope
      #: (String name, ?options: untyped, **untyped service_options) ?{ (ServiceBuilder s) -> untyped } -> untyped
      def service(name, options: nil, **service_options, &block)
        @draft.service(name, options: DSL.options(options, service_options)) do |s|
          block&.call(ServiceBuilder.new(s))
        end
      end
    end

    # The block argument of Scope#message
    class MessageBuilder < Scope
      # A field
      #
      # - `type`: :int32, :string, :message, :enum, :group, ...; a String is taken as
      #   the type name of a message or enum, its kind looked up when the file is built
      # - `type_name`: the message or enum type, e.g. ".acme.Person"
      # - `label`: :optional (the default), :required or :repeated
      # - `default`: the default as protoc stores it: text, C-escaped for bytes
      # - `json_name`: when not the one derived from the name
      # - `proto3_optional`: a proto3 `optional` field; its synthetic oneof is made for it
      # - `oneof`: the oneof the field belongs to
      # - `options`: FieldOptions verbatim
      #: ((Symbol | String) name, Integer number, (Symbol | String), ?String? type_name, ?label: Symbol?, ?default: untyped, ?json_name: String?, ?proto3_optional: bool, ?oneof: (Symbol | String)?, ?options: Hash[untyped, untyped]?, **untyped field_options) -> untyped
      def field(name, number, type, type_name = nil, label: nil, default: nil, json_name: nil, proto3_optional: nil,
        oneof: nil, options: nil, **field_options)
        @draft.field(name, number, DSL.type(type), type_name, label: DSL.label(label), default: default,
          json_name: json_name, optional: proto3_optional ? true : false, oneof: oneof,
          options: DSL.options(options, field_options))
      end

      # A `map<K, V>` field and its synthesized entry message
      #
      # - `value_type`: a scalar type, :message or :enum (then give `value_type_name`),
      #   or the value's type name
      #: (untyped name, untyped number, Symbol key_type, (Symbol | String) value_type, ?untyped value_type_name, ?json_name: untyped, ?options: untyped, **untyped field_options) -> untyped
      def map(name, number, key_type, value_type, value_type_name = nil, json_name: nil, options: nil, **field_options)
        value = value_type.is_a?(String) ? value_type : DSL.type(value_type)
        @draft.map(name, number, key: DSL.type(key_type), value: value, value_type_name: value_type_name,
          json_name: json_name, options: DSL.options(options, field_options))
      end

      # A proto2 group: a field of type group and its nested message, named as
      # in `group Name = number { ... }`
      #: (untyped name, untyped number, ?label: untyped, ?json_name: untyped, ?oneof: untyped, ?options: untyped, ?message_options: untyped, **untyped field_options) ?{ (MessageBuilder g) -> untyped } -> untyped
      def group(name, number, label: nil, json_name: nil, oneof: nil, options: nil, message_options: nil,
        **field_options, &block)
        @draft.group(name, number, label: DSL.label(label), json_name: json_name, oneof: oneof,
          options: DSL.options(options, field_options), message_options: message_options) do |g|
          block&.call(MessageBuilder.new(g))
        end
      end

      # A oneof. Fields given in the block belong to it; fields elsewhere may
      # name it with `oneof:`.
      #: (untyped name, ?options: untyped, **untyped oneof_options) ?{ (OneofBuilder o) -> untyped } -> untyped
      def oneof(name, options: nil, **oneof_options, &block)
        @draft.oneof(name.to_s, options: DSL.options(options, oneof_options))
        block&.call(OneofBuilder.new(self, name))
      end

      # Extension ranges, inclusive
      #: (*(Range[untyped] | Integer) ranges, ?options: untyped, **untyped range_options) -> untyped
      def extensions(*ranges, options: nil, **range_options)
        @draft.extensions(*ranges, options: DSL.options(options, range_options))
        self
      end

      # Reserved numbers (Integers or inclusive Ranges) and names (Strings)
      def reserved(*items)
        @draft.reserved(*items)
        self
      end
    end

    # The block argument of MessageBuilder#oneof
    class OneofBuilder
      def initialize(message, name) # :nodoc:
        @message = message
        @name = name
      end

      # A member field; same arguments as MessageBuilder#field
      def field(name, number, type, type_name = nil, **kwargs)
        @message.field(name, number, type, type_name, oneof: @name, **kwargs)
      end

      # A member group; same arguments as MessageBuilder#group
      def group(name, number, **kwargs, &block)
        @message.group(name, number, oneof: @name, **kwargs, &block)
      end
    end

    # The block argument of Scope#extend
    class ExtendBuilder
      def initialize(draft, extendee) # :nodoc:
        @draft = draft
        @extendee = extendee
      end

      # An extension field; same arguments as MessageBuilder#field
      def field(name, number, type, type_name = nil, label: nil, default: nil, json_name: nil, proto3_optional: nil,
        options: nil, **field_options)
        @draft.extension(name, number, DSL.type(type), type_name, extendee: @extendee, label: DSL.label(label),
          default: default, json_name: json_name, optional: proto3_optional ? true : false,
          options: DSL.options(options, field_options))
      end
    end

    # The block argument of Scope#enum
    class EnumBuilder
      def initialize(draft) # :nodoc:
        @draft = draft
      end

      #: ((Symbol | String) name, Integer number, ?options: untyped, **untyped value_options) -> untyped
      def value(name, number, options: nil, **value_options)
        @draft.value(name, number, options: DSL.options(options, value_options))
        self
      end

      # Reserved numbers (Integers or inclusive Ranges) and names (Strings)
      def reserved(*items)
        @draft.reserved(*items)
        self
      end
    end

    # The block argument of FileBuilder#service
    class ServiceBuilder
      def initialize(draft) # :nodoc:
        @draft = draft
      end

      # - `input_type`: e.g. ".acme.Request"
      #: ((Symbol | String) name, String input_type, String output_type, ?client_streaming: untyped, ?server_streaming: untyped, ?options: untyped, **untyped method_options) -> untyped
      def rpc(name, input_type, output_type, client_streaming: false, server_streaming: false, options: nil,
        **method_options)
        @draft.rpc(name, input_type, output_type, client_streaming: client_streaming,
          server_streaming: server_streaming, options: DSL.options(options, method_options))
        self
      end
    end
  end
end
