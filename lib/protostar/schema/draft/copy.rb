# frozen_string_literal: true

module Protostar
  module Schema
    module Draft
      # A copy of a built file for another pool, its imports taken from that
      # pool, with each descriptor's options replaced by what the block
      # returns (a MessageValue, or nil for none)
      # @param file [Schema::File]
      # @param pool [Pool] holds the copy's imports
      # @param source_info [SourceInfo, nil]
      # @yieldparam descriptor [Descriptor]
      # @return [Schema::File] frozen; not added to the pool
      def self.copy(file, pool:, source_info: file.source_info, &options)
        Copy.new(file, options).call(pool, source_info)
      end

      # @api private
      class Copy
        def initialize(file, options)
          @file = file
          @options = options
        end

        def call(pool, source_info)
          file = @file
          syntax = file.proto_syntax&.to_sym
          draft = Schema::File.draft(file.name, package: file.package, syntax: syntax, edition: file.edition,
            dependencies: file.dependencies, public_dependencies: file.public_dependencies,
            weak_dependencies: file.weak_dependencies, option_dependencies: file.option_dependencies,
            options: options(file))
          draft.source_info = source_info if source_info
          file.messages.each { |m| message(draft, m) }
          file.enums.each { |e| enum(draft, e) }
          file.extensions.each { |f| field(draft, f, nil) }
          file.services.each do |service|
            draft.service(service.name, options: options(service)) do |s|
              service.rpcs.each do |m|
                s.rpc(m.name, ".#{m.input_type.full_name}", ".#{m.output_type.full_name}",
                  client_streaming: m.client_streaming?, server_streaming: m.server_streaming?, options: options(m))
              end
            end
          end
          draft.resolve(pool).freeze!
        end

        private

        def options(descriptor)
          @options.call(descriptor)
        end

        def message(scope, message)
          scope.message(message.name, visibility: message.visibility, options: options(message)) do |m|
            oneofs = message.oneofs.map { |o| m.oneof(o.name, options: options(o)) }
            message.fields.each { |f| field(m, f, f.oneof && oneofs[f.oneof.index]) }
            message.nested_messages.each { |n| message(m, n) }
            message.nested_enums.each { |e| enum(m, e) }
            message.extensions.each { |f| field(m, f, nil) }
            message.extension_range_descriptors.each { |r| m.extension_range(r.range, options: options(r)) }
            message.reserved_ranges.each { |r| m.reserved(r) }
            m.reserved(*message.reserved_names)
          end
        end

        def field(scope, field, oneof)
          type_name = field.type_name && ".#{field.type_name}"
          kwargs = {label: field.declared_label, default: field.raw_default, json_name: field.json_name,
                    optional: field.proto3_optional?, options: options(field)}
          if field.extension?
            scope.extension(field.name, field.number, field.declared_type, type_name,
              extendee: ".#{field.extendee.full_name}", **kwargs)
          else
            scope.field(field.name, field.number, field.declared_type, type_name, oneof: oneof, **kwargs)
          end
        end

        def enum(scope, enum)
          scope.enum(enum.name, visibility: enum.visibility, options: options(enum)) do |e|
            enum.values.each { |v| e.value(v.name, v.number, options: options(v)) }
            enum.reserved_ranges.each { |r| e.reserved(r) }
            e.reserved(*enum.reserved_names)
          end
        end
      end
    end
  end
end
