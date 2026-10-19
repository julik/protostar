# frozen_string_literal: true

module Protostar
  class Compiler
    # protoc's StripSourceRetentionOptions (`compiler/retention.cc`): a copy
    # of a file without the options declared `retention = RETENTION_SOURCE`,
    # without options messages left empty by that, and without the source
    # locations under anything removed. protoc does this when it writes a
    # descriptor set or embeds descriptors in generated code; its pool keeps
    # the options for validating later files.
    module Retention # :nodoc: all
      # descriptor.proto field numbers of each descriptor's `options`
      OPTIONS_FIELD = {
        Schema::File => 8, Schema::Message => 7, Schema::Field => 8, Schema::Oneof => 2, Schema::Enum => 3,
        Schema::EnumValue => 3, Schema::Service => 3, Schema::Method => 4, Schema::ExtensionRange => 3
      }.freeze

      # - `pool`: holds the stripped copies of the file's imports
      # - `options_type`: options message full name to its Schema::Message
      #
      # Returns the stripped copy, not added to the pool.
      #: (Schema::File file, Schema::Pool pool, untyped options_type) -> Schema::File
      def self.strip(file, pool, options_type)
        stripped = []
        kept = {}.compare_by_identity
        source_paths(file).each do |descriptor, path|
          options = descriptor.options
          next unless options.declared?
          path += [OPTIONS_FIELD.fetch(descriptor.class)]
          value = strip_value(options, options_type.call(options.type_name), path, stripped)
          if !options.empty? && value.empty?
            stripped << path
            next
          end
          kept[descriptor] = value
        end
        info = file.source_info
        if info && !stripped.empty?
          info = Schema::SourceInfo.new(info.locations.reject { |loc| stripped.any? { |s| loc.path[0, s.size] == s } })
        end
        Schema::Draft.copy(file, pool: pool, source_info: info) { |descriptor| kept[descriptor] }
      end

      def self.strip_value(value, type, path, stripped)
        fields = {}
        value.fields.each do |name, v|
          field = type&.fields_by_name&.[](name.to_s)
          result = field ? strip_field(field, v, path, stripped) : v
          fields[name] = result unless result.equal?(DROP)
        end
        extensions = {}
        value.extensions.each do |field, v|
          result = strip_field(field, v, path, stripped)
          extensions[field] = result unless result.equal?(DROP)
        end
        Schema::MessageValue.new(fields, extensions, value.unknown_fields)
      end

      DROP = Object.new.freeze

      def self.strip_field(field, value, path, stripped)
        here = path + [field.number]
        if field.options.retention == :RETENTION_SOURCE
          stripped << here
          return DROP
        end
        return value unless field.type == :message || field.type == :group
        if field.repeated?
          value.each_with_index.map { |v, i| strip_value(v, field.message_type, here + [i], stripped) }
        else
          strip_value(value, field.message_type, here, stripped)
        end
      end

      # Each descriptor's path in its FileDescriptorProto, as source locations spell it
      def self.source_paths(file)
        paths = {file => []}.compare_by_identity
        visit = lambda do |m, path|
          paths[m] = path
          m.fields.each_with_index { |f, i| paths[f] = path + [2, i] }
          m.nested_messages.each_with_index { |n, i| visit.call(n, path + [3, i]) }
          m.nested_enums.each_with_index { |e, i| enum_paths(paths, e, path + [4, i]) }
          m.extension_range_descriptors.each_with_index { |r, i| paths[r] = path + [5, i] }
          m.extensions.each_with_index { |f, i| paths[f] = path + [6, i] }
          m.oneofs.each_with_index { |o, i| paths[o] = path + [8, i] }
        end
        file.messages.each_with_index { |m, i| visit.call(m, [4, i]) }
        file.enums.each_with_index { |e, i| enum_paths(paths, e, [5, i]) }
        file.services.each_with_index do |s, i|
          paths[s] = [6, i]
          s.rpcs.each_with_index { |m, j| paths[m] = [6, i, 2, j] }
        end
        file.extensions.each_with_index { |f, i| paths[f] = [7, i] }
        paths
      end

      def self.enum_paths(paths, enum, path)
        paths[enum] = path
        enum.values.each_with_index { |v, i| paths[v] = path + [2, i] }
      end
    end
  end
end
