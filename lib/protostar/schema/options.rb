# frozen_string_literal: true

module Protostar
  module Schema
    # A message-typed value in options: an options message itself, or a
    # message inside one (a `FeatureSet`, a custom option of a message type).
    # Fields are kept by name, extensions by their Field, and fields nobody
    # could interpret as their wire bytes.
    #
    # Values are Ruby values: Integers, Floats, Strings (binary for bytes),
    # true and false, enum values as Symbols (an Integer for a number the enum
    # does not name), repeated fields as frozen Arrays, messages as
    # MessageValues. Map fields are repeated entry messages.
    class MessageValue
      # Extension values by extension descriptor.
      attr_reader :extensions #: Hash[Field, untyped]
      # Binary, wire-format bytes of fields that could not be interpreted.
      attr_reader :unknown_fields #: String

      # - `unknown_fields`: binary
      #: (?Hash[Symbol, untyped] fields, ?Hash[Field, untyped] extensions, ?String unknown_fields) -> void
      def initialize(fields = Freezer::EMPTY_HASH, extensions = Freezer::EMPTY_HASH, unknown_fields = EMPTY_BYTES)
        @fields = frozen(fields)
        @extensions = frozen(extensions)
        @unknown_fields = if unknown_fields.empty?
          EMPTY_BYTES
        else
          unknown_fields.frozen? ? unknown_fields : unknown_fields.b.freeze
        end
      end

      # - `name`: a field of the message
      #
      # Returns its value, nil when not set.
      #: ((Symbol | String) name) -> untyped
      def [](name)
        @fields[name.to_sym]
      end

      # Returns whether the field is set.
      #: (untyped name) -> bool
      def key?(name)
        @fields.key?(name.to_sym)
      end
      alias_method :set?, :key?

      # The fields that are set, by name, in the order they were given.
      attr_reader :fields #: Hash[Symbol, untyped]

      # - `key`: an extension descriptor or its full name
      #
      # Returns the extension's value.
      #: ((Field | String) key) -> untyped
      def extension(key)
        return @extensions[key] if key.is_a?(Field)
        name = key.to_s.delete_prefix(".")
        @extensions.each { |field, value| return value if field.full_name == name }
        nil
      end

      # The same value with every extension, here and in nested values, looked
      # up again by full name; one that is not found stays as it was. A copy
      # of a file in another pool keys its options by that pool's extensions.
      #
      # - `extension`: full name to extension Field
      #: (untyped) -> MessageValue
      def rekey(extension) # :nodoc:
        changed = false
        again = lambda do |v|
          case v
          when MessageValue
            found = v.rekey(extension)
            changed ||= !found.equal?(v)
            found
          when Array then v.map(&again)
          else v
          end
        end
        fields = @fields.transform_values(&again)
        extensions = @extensions.to_h do |field, v|
          key = extension.call(field.full_name) || field
          changed ||= !key.equal?(field)
          [key, again.call(v)]
        end
        changed ? self.class.new(fields, extensions, @unknown_fields) : self
      end

      # Returns nothing set, not even unknown fields.
      #: () -> bool
      def empty?
        @fields.empty? && @extensions.empty? && @unknown_fields.empty?
      end

      # Protobuf merge semantics: `other`'s fields win, nested messages merge,
      # repeated fields concatenate
      #: (MessageValue? other) -> MessageValue
      def merge(other)
        return self if other.nil? || other.empty?
        return other if empty? && other.instance_of?(self.class)
        fields = MessageValue.merge_values(@fields, other.fields)
        extensions = MessageValue.merge_values(@extensions, other.extensions)
        unknown = @unknown_fields.empty? ? other.unknown_fields : (@unknown_fields + other.unknown_fields).freeze
        self.class.new(fields, extensions, unknown)
      end

      def self.merge_values(base, overlay) # :nodoc:
        return base if overlay.empty?
        return overlay if base.empty?
        base.merge(overlay) do |_key, old, new|
          if old.is_a?(MessageValue) && new.is_a?(MessageValue)
            old.merge(new)
          elsif old.is_a?(Array) && new.is_a?(Array)
            (old + new).freeze
          else
            new
          end
        end.freeze
      end

      def ==(other)
        other.instance_of?(self.class) && other.fields == @fields && other.extensions == @extensions &&
          other.unknown_fields == @unknown_fields
      end
      alias_method :eql?, :==

      def hash
        [self.class, @fields, @extensions, @unknown_fields].hash
      end

      # A plain Hash for reading: fields by name, extensions under their full
      # name in parentheses, nested messages as Hashes
      #: () -> Hash[untyped, untyped]
      def to_h
        h = @fields.transform_values { |v| MessageValue.plain(v) }
        @extensions.each { |field, v| h[:"(#{field.full_name})"] = MessageValue.plain(v) }
        h[:unknown_fields] = @unknown_fields unless @unknown_fields.empty?
        h
      end

      def self.plain(value) # :nodoc:
        case value
        when MessageValue then value.to_h
        when Array then value.map { |v| plain(v) }
        else value
        end
      end

      def inspect
        parts = @fields.map { |k, v| "#{k}: #{v.inspect}" }
        @extensions.each { |f, v| parts << "(#{f.full_name}): #{v.inspect}" }
        parts << "unknown_fields: #{@unknown_fields.bytesize} bytes" unless @unknown_fields.empty?
        parts.empty? ? "#<#{self.class.name}>" : "#<#{self.class.name} #{parts.join(", ")}>"
      end

      private

      def frozen(hash)
        return Freezer::EMPTY_HASH if hash.empty?
        hash.frozen? ? hash : hash.dup.freeze
      end

      public

      EMPTY_BYTES = "".b.freeze
      EMPTY = new.freeze
    end

    # The declared options of a descriptor: a message of descriptor.proto's
    # `FileOptions`, `FieldOptions` and so on, one subclass each. Every field
    # of that message has a reader (booleans also a `?` form); custom options
    # are #extension values; #features is what the descriptor resolves to.
    #
    # ```ruby
    # field.options.deprecated?               # => true
    # field.options.packed                    # => nil when not set
    # file.options.java_package               # => "com.acme"
    # message.options.extension("acme.limits") # => #<Protostar::Schema::MessageValue max: 10>
    # field.options[:features]                # => the FeatureSet as declared
    # field.options.features                  # => #<Protostar::Schema::Features ...> resolved
    # ```
    #
    # A reader answers what was declared: nil (or an empty Array) when the
    # option was not set, not descriptor.proto's default.
    class Options < MessageValue
      TYPE_NAME = nil
      FIELDS = Freezer::EMPTY_ARRAY

      class << self
        # Returns full name of the options message, e.g. "google.protobuf.FieldOptions".
        #: () -> String
        def type_name
          self::TYPE_NAME
        end

        def define(type_name, *names, booleans: [], repeated: []) # :nodoc:
          klass = Class.new(self)
          klass.const_set(:TYPE_NAME, -"google.protobuf.#{type_name}")
          names.each do |name|
            if repeated.include?(name)
              klass.define_method(name) { @fields.fetch(name, Freezer::EMPTY_ARRAY) }
            else
              klass.define_method(name) { @fields[name] }
            end
          end
          booleans.each do |name|
            klass.define_method(name) { @fields[name] }
            klass.define_method(:"#{name}?") { @fields[name] == true }
          end
          klass.const_set(:FIELDS, (names + booleans + [:features]).freeze)
          klass
        end

        # Options built from what a draft was given: nil, an Options or
        # MessageValue, or a Hash of field values by name with custom options
        # under `extensions:` (by full name or Field) and wire bytes under
        # `unknown_fields:`. Message values may be Hashes in the same spelling.
        #
        # - `extension`: full name to extension Field
        #
        # Returns options without resolved #features.
        #: ((Hash[untyped, untyped] | MessageValue)? spec, untyped, untyped owner) -> Options?
        def build(spec, extension, owner) # :nodoc:
          case spec
          when nil then nil
          when MessageValue
            value = spec.rekey(extension)
            new(value.fields, value.extensions, value.unknown_fields, declared: true)
          when Hash
            value = MessageValue.from_hash(spec, extension, owner)
            new(value.fields, value.extensions, value.unknown_fields, declared: true)
          else raise Error, "#{owner}: options must be a Hash, got #{spec.class}"
          end
        end
      end

      # - `features`: resolved features of the descriptor
      # - `declared`: whether the descriptor carries an options message, even an empty one
      #: (?untyped fields, ?untyped extensions, ?untyped unknown_fields, ?features: Features?, ?declared: bool) -> void
      def initialize(fields = Freezer::EMPTY_HASH, extensions = Freezer::EMPTY_HASH, unknown_fields = EMPTY_BYTES,
        features: nil, declared: false)
        super(fields, extensions, unknown_fields)
        @features = features
        @declared = declared
      end

      # The features the descriptor resolves to, nil before resolution.
      attr_reader :features #: Features?

      # Returns whether the descriptor carries an options message (protoc writes `options {}`
      # for one declared empty).
      #: () -> bool
      def declared? # :nodoc:
        @declared
      end

      # Returns the same options, bound to resolved features.
      #: (untyped features) -> Options
      def with_features(features) # :nodoc:
        self.class.new(@fields, @extensions, @unknown_fields, features: features, declared: @declared)
      end

      # Returns a name such as "google.protobuf.FieldOptions".
      #: () -> String
      def type_name
        self.class.type_name
      end

      def inspect
        @declared ? super : "#<#{self.class.name} (none declared)>"
      end

      # Returned by descriptors before they are resolved
      EMPTY = new.freeze

      # These options as the descriptor.proto message they are (a
      # `Protostar::Google::Protobuf::FieldOptions`, say), custom options as
      # extension bytes the message keeps as unknown fields
      #: () -> Protostar::Message
      def to_proto
        klass = Proto.types.const_get(type_name.delete_prefix("google.protobuf."))
        klass.decode(encode(klass.descriptor))
      end
    end

    FileOptions = Options.define("FileOptions", :java_package, :java_outer_classname, :optimize_for, :go_package,
      :objc_class_prefix, :csharp_namespace, :swift_prefix, :php_class_prefix, :php_namespace,
      :php_metadata_namespace, :ruby_package,
      booleans: %i[java_multiple_files java_generate_equals_and_hash java_string_check_utf8 cc_generic_services
        java_generic_services py_generic_services deprecated cc_enable_arenas])
    MessageOptions = Options.define("MessageOptions",
      booleans: %i[message_set_wire_format no_standard_descriptor_accessor deprecated map_entry
        deprecated_legacy_json_field_conflicts])
    FieldOptions = Options.define("FieldOptions", :ctype, :jstype, :retention, :targets, :edition_defaults,
      :feature_support, booleans: %i[packed lazy unverified_lazy deprecated weak debug_redact],
      repeated: %i[targets edition_defaults])
    OneofOptions = Options.define("OneofOptions")
    EnumOptions = Options.define("EnumOptions",
      booleans: %i[allow_alias deprecated deprecated_legacy_json_field_conflicts])
    EnumValueOptions = Options.define("EnumValueOptions", :feature_support, booleans: %i[deprecated debug_redact])
    ServiceOptions = Options.define("ServiceOptions", booleans: %i[deprecated])
    MethodOptions = Options.define("MethodOptions", :idempotency_level, booleans: %i[deprecated])
    ExtensionRangeOptions = Options.define("ExtensionRangeOptions", :declaration, :verification,
      repeated: %i[declaration])

    class MessageValue
      # A value from a Hash: fields by name, `extensions:` by full name or
      # Field, `unknown_fields:` as bytes. A field named `extensions` or
      # `unknown_fields` takes a String key. `__extensions:` and
      # `__unknown_fields:` (as `[number, wire_type, bytes]` triples) are the
      # deprecated spellings.
      def self.from_hash(hash, extension, owner) # :nodoc:
        fields = {}
        extensions = {}
        unknown = EMPTY_BYTES
        hash.each do |key, value|
          case key
          when :extensions, :__extensions
            Protostar.deprecated("__extensions:", "extensions:") if key == :__extensions
            value.each do |name, v|
              field = name.is_a?(Field) ? name : extension.call(name.to_s.delete_prefix("."))
              raise Error, "#{owner}: option extension #{name} is not defined here or in an import" unless field
              extensions[field] = from_value(v, extension, owner)
            end
          when :unknown_fields then unknown = value.b.freeze
          when :__unknown_fields
            Protostar.deprecated("__unknown_fields: [[number, wire_type, bytes]]", "unknown_fields: \"bytes\".b")
            unknown = unknown_bytes(value)
          else fields[key.to_sym] = from_value(value, extension, owner)
          end
        end
        new(fields.freeze, extensions.freeze, unknown)
      end

      def self.from_value(value, extension, owner) # :nodoc:
        case value
        when MessageValue then value
        when Hash then from_hash(value, extension, owner)
        when Array then value.map { |v| from_value(v, extension, owner) }.freeze
        else Freezer.call(value)
        end
      end

      def self.unknown_bytes(triples) # :nodoc:
        out = "".b
        triples.each do |number, wire_type, bytes|
          w = Wire::Writer.new(out)
          w.write_tag(number, wire_type)
          w.flush
          out << bytes.b
        end
        out.freeze
      end

      # This value in wire format
      #
      # - `type`: the message type it is a value of
      #
      # Returns a binary String.
      #: (Message) -> String
      def encode(type)
        Proto::Codec.encode(type, self)
      end

      # - `extensions`: (extendee full name, number) to an extension Field;
      #   fields it does not know stay in #unknown_fields
      #: (Message, String bytes, ?untyped extensions) -> MessageValue
      def self.decode(type, bytes, extensions = nil)
        Proto::Codec.decode(type, bytes, extensions)
      end
    end
  end
end
