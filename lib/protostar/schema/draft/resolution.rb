# frozen_string_literal: true

module Protostar
  module Schema
    module Draft
      # Options, features and defaults of a linked file, as protoc's
      # DescriptorBuilder resolves them once options are known
      # @api private
      class Resolution
        OPTIONS = {
          Schema::File => FileOptions, Schema::Message => MessageOptions, Field => FieldOptions,
          Schema::Oneof => OneofOptions, Schema::Enum => EnumOptions, EnumValue => EnumValueOptions,
          Schema::Service => ServiceOptions, Schema::Method => MethodOptions,
          ExtensionRange => ExtensionRangeOptions
        }.freeze

        def initialize(file, fields, specs, pool)
          @file = file
          @fields = fields
          @specs = specs
          @pool = pool
          @features = {}
          @empty = {}
        end

        def call
          finder = extension_finder
          @declared = {}.compare_by_identity
          @specs.each do |descriptor, spec|
            options = OPTIONS.fetch(descriptor.class).build(spec, finder, descriptor.full_name)
            @declared[descriptor] = options if options
          end
          resolve_features
          parse_defaults
        end

        private

        # Custom options are extensions of this file, its imports and theirs,
        # or else of whatever the pool holds (`import option` files)
        def extension_finder
          files = []
          seen = {}
          queue = [@file]
          until queue.empty?
            f = queue.shift
            next if seen[f.name]
            seen[f.name] = true
            files << f
            queue.concat(f.dependency_files)
          end
          lambda do |name|
            files.each do |f|
              found = f.find_extension(name)
              return found if found
            end
            found = @pool&.find_symbol(name)
            found if found.is_a?(Field) && found.extension?
          end
        end

        def declared(descriptor)
          @declared[descriptor]
        end

        # Options of this file's messages are bound in tree order, so a
        # message type elsewhere in the file may not be bound yet
        def map_entry?(message)
          return message.map_entry? unless message.file.equal?(@file)
          declared(message)&.[](:map_entry) == true
        end

        def bind(descriptor, features)
          options = @declared[descriptor]
          bound = if options
            options.with_features(features)
          else
            klass = OPTIONS.fetch(descriptor.class)
            (@empty[klass] ||= {})[features] ||= klass.new(features: features)
          end
          descriptor.__link(features: features, options: bound)
        end

        def resolve_features
          file_features = intern(Features.defaults(@file.edition_number).merge(declared(@file)&.[](:features)))
          bind(@file, file_features)
          @file.messages.each { |m| resolve_message_features(m, file_features) }
          @file.enums.each { |e| resolve_enum_features(e, file_features) }
          @file.extensions.each { |f| resolve_field_features(f, file_features) }
          @file.services.each do |service|
            service_features = inherit(file_features, service)
            service.rpcs.each { |m| inherit(service_features, m) }
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
          options = declared(field)
          features = parent.merge(options&.[](:features))
          if @file.syntax != :editions
            legacy = nil
            legacy = {field_presence: :LEGACY_REQUIRED} if field.declared_label == :required
            (legacy ||= {})[:message_encoding] = :DELIMITED if field.declared_type == :group
            if options&.key?(:packed)
              (legacy ||= {})[:repeated_field_encoding] = options[:packed] ? :PACKED : :EXPANDED
            end
            (legacy ||= {})[:field_presence] = :EXPLICIT if field.proto3_optional?
            features = features.with(**legacy) if legacy
          end
          features = intern(features)
          label = field.declared_label
          label = :required if label == :optional && features.field_presence == :LEGACY_REQUIRED
          type = field.declared_type
          if type == :message && features.message_encoding == :DELIMITED
            holder = field.extension? ? field.extendee : field.containing_message
            type = :group unless map_entry?(holder) || map_entry?(field.message_type)
          end
          bind(field, features)
          field.__link(label: label, type: type)
        end

        def inherit(parent, descriptor)
          features = intern(parent.merge(declared(descriptor)&.[](:features)))
          bind(descriptor, features)
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
                raise Error, "#{@file.name}: #{field.full_name}: #{e.message}"
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
      end
    end

    class Options
      # What a descriptor answers before its options are resolved: an empty
      # instance of its options class
      UNRESOLVED = Draft::Resolution::OPTIONS.transform_values { |klass| klass.new.freeze }.freeze
    end
  end
end
