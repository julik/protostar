# frozen_string_literal: true

module Protostar
  class Compiler
    # protoc's StripSourceRetentionOptions (`compiler/retention.cc`): removes
    # options declared `retention = RETENTION_SOURCE` from a descriptor hash,
    # drops options messages left empty by that, and drops the source
    # locations under anything removed. protoc does this when it writes a
    # descriptor set or embeds descriptors in generated code; its pool keeps
    # the options for validating later files.
    #
    # @api private
    module Retention
      # @param hash [Hash] a FileDescriptorProto hash
      # @param file_type [Schema::Message] google.protobuf.FileDescriptorProto
      # @param extensions [#call] full name to extension {Schema::Field}, or nil
      # @return [Hash] a stripped copy
      def self.strip(hash, file_type, extensions)
        stripped = []
        out = walk(hash, file_type, extensions, [], stripped)
        if (info = out[:source_code_info]) && !stripped.empty?
          locations = info[:location].reject do |loc|
            path = loc[:path] || []
            stripped.any? { |s| path[0, s.size] == s }
          end
          out = out.merge(source_code_info: {location: locations})
        end
        out
      end

      def self.walk(hash, type, extensions, path, stripped)
        out = {}
        hash.each do |key, value|
          if key == :__extensions
            kept = {}
            value.each do |name, ext_value|
              field = extensions.call(name)
              if field.nil?
                kept[name] = ext_value
                next
              end
              result = strip_field(field, ext_value, extensions, path, stripped)
              kept[name] = result unless result.equal?(DROP)
            end
            out[key] = kept unless kept.empty? && !value.empty?
            next
          end
          field = (key == :__unknown_fields) ? nil : type.fields_by_name[key.to_s]
          if field.nil?
            out[key] = value
            next
          end
          result = strip_field(field, value, extensions, path, stripped)
          out[key] = result unless result.equal?(DROP)
        end
        out
      end

      DROP = Object.new.freeze

      def self.strip_field(field, value, extensions, path, stripped)
        here = path + [field.number]
        if field.options[:retention] == :RETENTION_SOURCE
          stripped << here
          return DROP
        end
        return value unless field.type == :message || field.type == :group
        if field.repeated?
          value.each_with_index.map { |v, i| walk(v, field.message_type, extensions, here + [i], stripped) }
        else
          child = walk(value, field.message_type, extensions, here, stripped)
          if options_type?(field.message_type) && !empty?(value) && empty?(child)
            stripped << here
            return DROP
          end
          child
        end
      end

      def self.options_type?(type)
        type.file.name == "google/protobuf/descriptor.proto" && type.name.end_with?("Options")
      end

      def self.empty?(hash)
        hash.all? { |k, v| (k == :__extensions || k == :__unknown_fields) && v.empty? }
      end
    end
  end
end
