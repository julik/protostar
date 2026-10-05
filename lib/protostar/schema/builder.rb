# frozen_string_literal: true

module Protostar
  module Schema
    # Turns a descriptor hash (shaped like `FileDescriptorProto#to_h`) into a
    # linked, frozen, Ractor-shareable {File}.
    #
    # It checks the shape of the hash and resolves every reference, but leaves
    # semantic validation (duplicate numbers, reserved clashes and the like) to
    # the compiler. It does not add the file to the pool.
    class Builder
      FILE_KEYS = %i[name package dependency public_dependency weak_dependency option_dependency message_type
        enum_type service extension options source_code_info syntax edition].freeze
      MESSAGE_KEYS = %i[name field extension nested_type enum_type extension_range oneof_decl options
        reserved_range reserved_name visibility].freeze
      FIELD_KEYS = %i[name number label type type_name extendee default_value oneof_index json_name options
        proto3_optional].freeze
      ONEOF_KEYS = %i[name options].freeze
      ENUM_KEYS = %i[name value options reserved_range reserved_name visibility].freeze
      ENUM_VALUE_KEYS = %i[name number options].freeze
      SERVICE_KEYS = %i[name method options].freeze
      METHOD_KEYS = %i[name input_type output_type options client_streaming server_streaming].freeze
      RANGE_KEYS = %i[start end options].freeze
      RESERVED_RANGE_KEYS = %i[start end].freeze

      SYNTAXES = {nil => :proto2, "proto2" => :proto2, "proto3" => :proto3, "editions" => :editions}.freeze
      TYPED = %i[TYPE_MESSAGE TYPE_GROUP TYPE_ENUM].freeze

      # @param hash [Hash] a FileDescriptorProto hash
      # @param pool [Pool] where the file's dependencies are looked up
      # @return [File] frozen and shareable
      # @raise [Error, ResolveError]
      def self.build(hash, pool:)
        new(hash, pool).build
      end

      # The JSON name protoc derives from a field name: underscores dropped,
      # the letter after each one upper-cased
      # @param name [String]
      # @return [String]
      def self.json_name(name)
        out = +""
        upper = false
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

      # @api private
      def initialize(hash, pool)
        raise Error, "a FileDescriptorProto must be a Hash, got #{hash.class}" unless hash.is_a?(Hash)
        @hash = hash
        @pool = pool
        @messages = []
        @fields = []
        @methods = []
        @features = {}
      end

      # @api private
      def build
        build_file
        link_fields
        link_methods
        resolve_features
        parse_defaults
        deep_freeze(@file)
        Ractor.make_shareable(@file)
      end

      private

      # Ractor.make_shareable on a graph full of back-references (every field
      # points at its message, which points at all its fields) re-checks the
      # graph from each back-reference and goes quadratic: about 1.4s for
      # unittest.proto. Freezing everything first lets it confirm the graph in one pass.
      #
      # Collections are frozen early during building while their members are
      # not, so they are always descended into; other frozen objects are
      # either finished descriptors of dependencies or immutable values.
      def deep_freeze(root)
        stack = [root]
        containers = {}.compare_by_identity
        until stack.empty?
          obj = stack.pop
          case obj
          when Array
            next if containers.key?(obj)
            containers[obj] = true
            stack.concat(obj)
          when Hash
            next if containers.key?(obj)
            containers[obj] = true
            obj.each { |k, v| stack << k << v }
          else
            next if obj.frozen?
            obj.instance_variables.each { |ivar| stack << obj.instance_variable_get(ivar) }
          end
          obj.freeze
        end
      end

      def build_file
        h = @hash
        check_keys(h, FILE_KEYS, "FileDescriptorProto")
        name = string!(h, :name, "FileDescriptorProto")
        @context = name
        package = string(h, :package) || ""
        dependencies = strings(h, :dependency)
        dependency_files = dependencies.map do |dep|
          @pool.file(dep) || raise(Error, "#{name}: dependency \"#{dep}\" is not in the pool")
        end
        public_deps = dependency_indexes(h, :public_dependency, dependencies)
        weak_deps = dependency_indexes(h, :weak_dependency, dependencies)
        syntax, edition, proto_syntax = syntax_and_edition(h)

        @file = File.new(
          name: name, package: package, syntax: syntax, edition: edition, proto_syntax: proto_syntax,
          dependencies: dependencies, public_dependencies: public_deps, weak_dependencies: weak_deps,
          option_dependencies: strings(h, :option_dependency), dependency_files: dependency_files.freeze,
          options: options(h), source_info: h[:source_code_info] && SourceInfo.new(h[:source_code_info])
        )

        messages = each_entry(h, :message_type) { |m, i| build_message(m, i, package, nil) }
        enums = each_entry(h, :enum_type) { |e, i| build_enum(e, i, package, nil) }
        services = each_entry(h, :service) { |s, i| build_service(s, i, package) }
        extensions = each_entry(h, :extension) { |f, i| build_field(f, i, package, nil, extension: true) }
        @file.__link(
          messages: messages, enums: enums, services: services, extensions: extensions,
          all_messages: @messages.freeze,
          all_enums: (enums + @messages.flat_map(&:nested_enums)).freeze,
          all_extensions: (extensions + @messages.flat_map(&:extensions)).freeze
        )
      end

      def syntax_and_edition(h)
        proto_syntax = string(h, :syntax)
        unless SYNTAXES.key?(proto_syntax)
          raise Error, "#{@context}: unknown syntax #{proto_syntax.inspect}"
        end
        edition = h[:edition]
        edition = Features::EDITION_NAMES.fetch(edition, edition) if edition.is_a?(Integer)
        if edition && !edition.is_a?(Integer) && !Features::EDITIONS.key?(edition)
          raise Error, "#{@context}: unknown edition #{edition.inspect}"
        end
        syntax = SYNTAXES[proto_syntax]
        syntax = :editions if edition && proto_syntax.nil?
        if syntax == :editions && edition.nil?
          raise Error, "#{@context}: syntax \"editions\" needs an edition"
        elsif syntax != :editions && edition
          raise Error, "#{@context}: syntax #{proto_syntax.inspect} cannot have an edition"
        end
        [syntax, edition, proto_syntax]
      end

      def build_message(h, index, scope, parent)
        check_keys(h, MESSAGE_KEYS, "DescriptorProto")
        name = string!(h, :name, "DescriptorProto")
        full_name = qualify(scope, name)
        message = Message.new(
          name: name, full_name: full_name, file: @file, containing_message: parent, index: index,
          options: options(h), reserved_ranges: ranges(h, :reserved_range, RESERVED_RANGE_KEYS, 1),
          reserved_names: strings(h, :reserved_name), visibility: h[:visibility]
        )
        register(full_name, message)
        @messages << message

        oneofs = each_entry(h, :oneof_decl) do |o, i|
          check_keys(o, ONEOF_KEYS, "OneofDescriptorProto")
          oneof_name = string!(o, :name, "OneofDescriptorProto")
          oneof = Oneof.new(name: oneof_name, full_name: "#{full_name}.#{oneof_name}", containing_message: message,
            index: i, options: options(o))
          register(oneof.full_name, oneof)
        end
        fields = each_entry(h, :field) do |f, i|
          build_field(f, i, full_name, message, extension: false, oneofs: oneofs)
        end
        oneofs.each do |oneof|
          members = oneof.fields.freeze
          oneof.__link(synthetic: members.size == 1 && members.first.proto3_optional?)
        end
        nested = each_entry(h, :nested_type) { |m, i| build_message(m, i, full_name, message) }
        enums = each_entry(h, :enum_type) { |e, i| build_enum(e, i, full_name, message) }
        extensions = each_entry(h, :extension) { |f, i| build_field(f, i, full_name, message, extension: true) }
        extension_ranges = each_entry(h, :extension_range) do |r, i|
          check_keys(r, RANGE_KEYS, "ExtensionRange")
          ExtensionRange.new(containing_message: message, index: i, range: range(r, 1), options: options(r))
        end
        message.__members(
          fields: fields, oneofs: oneofs, nested_messages: nested, nested_enums: enums,
          extensions: extensions, extension_range_descriptors: extension_ranges
        )
      end

      def build_field(h, index, scope, message, extension:, oneofs: nil)
        check_keys(h, FIELD_KEYS, "FieldDescriptorProto")
        name = string!(h, :name, "FieldDescriptorProto")
        full_name = qualify(scope, name)
        number = h[:number]
        raise Error, "#{@context}: #{full_name} has no integer number" unless number.is_a?(Integer)
        label = h[:label] || :LABEL_OPTIONAL
        raise Error, "#{@context}: #{full_name} has unknown label #{label.inspect}" unless Field::LABELS.key?(label)
        type = h[:type]
        if type && !Field::TYPES.key?(type)
          raise Error, "#{@context}: #{full_name} has unknown type #{type.inspect}"
        end
        type_name = string(h, :type_name)
        if type_name.nil? && (type.nil? || TYPED.include?(type))
          raise Error, "#{@context}: #{full_name} needs a type_name"
        elsif type_name && type && !TYPED.include?(type)
          raise Error, "#{@context}: #{full_name} is a #{type} and cannot have a type_name"
        end
        extendee = string(h, :extendee)
        if extension && extendee.nil?
          raise Error, "#{@context}: extension #{full_name} has no extendee"
        elsif !extension && extendee
          raise Error, "#{@context}: field #{full_name} has an extendee but is not an extension"
        end

        field = Field.new(
          name: name, full_name: full_name, number: number, proto_label: label, proto_type: type,
          type_name: type_name, extendee_name: extendee, raw_default: string(h, :default_value),
          json_name: string(h, :json_name) || -Builder.json_name(name),
          proto3_optional: h[:proto3_optional] == true, extension: extension, containing_message: message,
          file: @file, index: index, options: options(h)
        )
        if (oneof_index = h[:oneof_index])
          oneof = !extension && oneof_index.is_a?(Integer) && oneof_index >= 0 && oneofs[oneof_index]
          raise Error, "#{@context}: #{full_name} has an invalid oneof_index #{oneof_index.inspect}" unless oneof
          oneof.fields << field
          field.__link(oneof: oneof)
        end
        register(full_name, field)
        @fields << [field, scope]
        field
      end

      def build_enum(h, index, scope, parent)
        check_keys(h, ENUM_KEYS, "EnumDescriptorProto")
        name = string!(h, :name, "EnumDescriptorProto")
        full_name = qualify(scope, name)
        enum = Enum.new(
          name: name, full_name: full_name, file: @file, containing_message: parent, index: index,
          options: options(h), reserved_ranges: ranges(h, :reserved_range, RESERVED_RANGE_KEYS, 0),
          reserved_names: strings(h, :reserved_name), visibility: h[:visibility]
        )
        register(full_name, enum)
        values = each_entry(h, :value) do |v, i|
          check_keys(v, ENUM_VALUE_KEYS, "EnumValueDescriptorProto")
          value_name = string!(v, :name, "EnumValueDescriptorProto")
          number = v[:number]
          raise Error, "#{@context}: enum value #{value_name} has no integer number" unless number.is_a?(Integer)
          value = EnumValue.new(name: value_name, full_name: qualify(scope, value_name), number: number,
            enum: enum, index: i, options: options(v))
          register(value.full_name, value)
        end
        enum.__values(values)
      end

      def build_service(h, index, scope)
        check_keys(h, SERVICE_KEYS, "ServiceDescriptorProto")
        name = string!(h, :name, "ServiceDescriptorProto")
        service = Service.new(name: name, full_name: qualify(scope, name), file: @file, index: index,
          options: options(h))
        register(service.full_name, service)
        methods = each_entry(h, :method) do |m, i|
          check_keys(m, METHOD_KEYS, "MethodDescriptorProto")
          method_name = string!(m, :name, "MethodDescriptorProto")
          method = Method.new(
            name: method_name, full_name: "#{service.full_name}.#{method_name}", service: service, index: i,
            options: options(m), input_type_name: string!(m, :input_type, "MethodDescriptorProto"),
            output_type_name: string!(m, :output_type, "MethodDescriptorProto"),
            client_streaming: m[:client_streaming] == true, server_streaming: m[:server_streaming] == true
          )
          register(method.full_name, method)
          @methods << method
          method
        end
        service.__methods(methods)
      end

      def link_fields
        @fields.each do |field, scope|
          attrs = {}
          if field.type_name
            target = resolve(field.type_name, scope, field)
            proto_type = field.proto_type
            case target
            when Message
              proto_type ||= :TYPE_MESSAGE
              unless proto_type == :TYPE_MESSAGE || proto_type == :TYPE_GROUP
                raise ResolveError.new("#{@context}: #{field.full_name}: \"#{field.type_name}\" is not an enum type",
                  name: field.type_name, scope: scope)
              end
              attrs[:message_type] = target
            when Enum
              proto_type ||= :TYPE_ENUM
              unless proto_type == :TYPE_ENUM
                raise ResolveError.new("#{@context}: #{field.full_name}: \"#{field.type_name}\" is not a message type",
                  name: field.type_name, scope: scope)
              end
              attrs[:enum_type] = target
            else
              raise ResolveError.new("#{@context}: #{field.full_name}: \"#{field.type_name}\" is not a type",
                name: field.type_name, scope: scope)
            end
            attrs.merge!(type_name: target.full_name, proto_type: proto_type, type: Field::TYPES.fetch(proto_type))
          end
          if field.extension?
            extendee = resolve(field.extendee_name, scope, field)
            unless extendee.is_a?(Message)
              raise ResolveError.new("#{@context}: #{field.full_name}: \"#{field.extendee_name}\" is not a message type",
                name: field.extendee_name, scope: scope)
            end
            attrs[:extendee] = extendee
          end
          field.__link(**attrs) unless attrs.empty?
        end
      end

      def link_methods
        @methods.each do |method|
          scope = method.service.full_name
          input = resolve(method.input_type_name, scope, method)
          output = resolve(method.output_type_name, scope, method)
          [[method.input_type_name, input], [method.output_type_name, output]].each do |written, found|
            next if found.is_a?(Message)
            raise ResolveError.new("#{@context}: #{method.full_name}: \"#{written}\" is not a message type",
              name: written, scope: scope)
          end
          method.__link(input_type: input, output_type: output)
        end
      end

      def resolve(name, scope, element)
        Resolver.resolve(name, scope: scope, file: @file, pool: @pool)
      rescue ResolveError => e
        raise ResolveError.new("#{@context}: #{element.full_name}: #{e.message}", name: e.name, scope: e.scope)
      end

      def resolve_features
        file_features = intern(Features.defaults(@file.edition_number).merge(@file.options.features))
        @file.__link(features: file_features)
        @file.messages.each { |m| resolve_message_features(m, file_features) }
        @file.enums.each { |e| resolve_enum_features(e, file_features) }
        @file.extensions.each { |f| resolve_field_features(f, file_features) }
        @file.services.each do |service|
          service_features = inherit(file_features, service)
          service.methods.each { |m| inherit(service_features, m) }
        end
      end

      def resolve_message_features(message, parent)
        features = inherit(parent, message)
        message.oneofs.each { |o| inherit(features, o) }
        message.fields.each { |f| resolve_field_features(f, f.oneof ? f.oneof.features : features) }
        message.extension_range_descriptors.each { |r| inherit(features, r) }
        message.nested_messages.each { |m| resolve_message_features(m, features) }
        message.nested_enums.each { |e| resolve_enum_features(e, features) }
        message.extensions.each { |f| resolve_field_features(f, features) }
      end

      def resolve_enum_features(enum, parent)
        features = inherit(parent, enum)
        enum.values.each { |v| inherit(features, v) }
      end

      # protoc's InferLegacyProtoFeatures for proto2 and proto3 files, then the
      # label and type adjustments of DescriptorBuilder::PostProcessFieldFeatures
      def resolve_field_features(field, parent)
        features = parent.merge(field.options.features)
        if @file.syntax != :editions
          legacy = {}
          legacy[:field_presence] = :LEGACY_REQUIRED if field.label == :required
          legacy[:message_encoding] = :DELIMITED if field.proto_type == :TYPE_GROUP
          legacy[:repeated_field_encoding] = field.options[:packed] ? :PACKED : :EXPANDED if field.options.key?(:packed)
          legacy[:field_presence] = :EXPLICIT if field.proto3_optional?
          features = features.merge(legacy)
        end
        features = intern(features)
        attrs = {features: features}
        attrs[:label] = :required if field.label == :optional && features.field_presence == :LEGACY_REQUIRED
        if field.type == :message && features.message_encoding == :DELIMITED
          holder = field.extension? ? field.extendee : field.containing_message
          attrs[:type] = :group unless holder.map_entry? || field.message_type.map_entry?
        end
        field.__link(**attrs)
      end

      def inherit(parent, descriptor)
        features = intern(parent.merge(descriptor.options.features))
        descriptor.__link(features: features)
        features
      end

      def intern(features)
        @features[features] ||= features
      end

      def parse_defaults
        @fields.each do |field, _scope|
          value = nil
          if (text = field.raw_default)
            begin
              value = DefaultValue.parse(text, field.type, field.enum_type)
            rescue Error => e
              raise Error, "#{@context}: #{field.full_name}: #{e.message}"
            end
          end
          implicit = if !value.nil?
            value
          elsif field.type == :enum
            field.enum_type.values.first&.name&.to_sym
          else
            Field::ZERO[field.type]
          end
          field.__link(default_value: value, default: implicit)
        end
      end

      def register(full_name, descriptor)
        if (existing = @file.symbols[full_name])
          raise Error, "#{@context}: \"#{full_name}\" is defined twice (#{existing.class.name.split("::").last} " \
            "and #{descriptor.class.name.split("::").last})"
        end
        @file.symbols[full_name] = descriptor
      end

      def qualify(scope, name)
        -(scope.empty? ? name : "#{scope}.#{name}")
      end

      def check_keys(h, allowed, what)
        raise Error, "#{@context}: a #{what} must be a Hash, got #{h.class}" unless h.is_a?(Hash)
        h.each_key do |key|
          next if allowed.include?(key)
          raise Error, "#{@context}: unknown key #{key.inspect} in #{what} #{h[:name].inspect}"
        end
      end

      def string(h, key)
        value = h[key]
        return nil if value.nil?
        raise Error, "#{@context}: #{key} must be a String, got #{value.inspect}" unless value.is_a?(String)
        -value
      end

      def string!(h, key, what)
        string(h, key) || raise(Error, "#{@context}: #{what} without a #{key}: #{h.inspect[0, 200]}")
      end

      def strings(h, key)
        list = array(h, key)
        return Freezer::EMPTY_ARRAY if list.empty?
        list.map do |s|
          raise Error, "#{@context}: #{key} must hold Strings, got #{s.inspect}" unless s.is_a?(String)
          -s
        end.freeze
      end

      def array(h, key)
        value = h[key]
        return Freezer::EMPTY_ARRAY if value.nil?
        raise Error, "#{@context}: #{key} must be an Array, got #{value.class}" unless value.is_a?(Array)
        value
      end

      def each_entry(h, key, &block)
        list = array(h, key)
        return Freezer::EMPTY_ARRAY if list.empty?
        list.each_with_index.map(&block).freeze
      end

      def dependency_indexes(h, key, dependencies)
        indexes = array(h, key)
        indexes.each do |i|
          next if i.is_a?(Integer) && i >= 0 && i < dependencies.size
          raise Error, "#{@context}: #{key} #{i.inspect} is not an index into dependency"
        end
        indexes.empty? ? Freezer::EMPTY_ARRAY : indexes.dup.freeze
      end

      # `end_offset` is 1 where descriptor.proto makes `end` exclusive, 0 where inclusive
      def ranges(h, key, keys, end_offset)
        each_entry(h, key) do |r, _|
          check_keys(r, keys, key.to_s)
          range(r, end_offset)
        end
      end

      def range(r, end_offset)
        first = r[:start]
        last = r[:end]
        unless first.is_a?(Integer) && last.is_a?(Integer)
          raise Error, "#{@context}: a range needs integer start and end, got #{r.inspect}"
        end
        first..(last - end_offset)
      end

      def options(h)
        return nil unless h.key?(:options) && !h[:options].nil?
        raw = h[:options]
        raise Error, "#{@context}: options must be a Hash, got #{raw.class}" unless raw.is_a?(Hash)
        Options.new(Freezer.call(raw))
      end
    end
  end
end
