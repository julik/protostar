# frozen_string_literal: true

require "monitor"

module Google
  module Protobuf
    # A set of files and the message classes and enum modules made from them.
    # Generated `_pb.rb` files add their file to {generated_pool}.
    #
    # Each pool has its own protostar {Protostar::Schema::Pool} and
    # {Protostar::Types::Registry}, separate from `Protostar.generated_pool`
    # and the global registry: classes made here carry the google-protobuf
    # API, classes made by `Protostar::DSL` carry protostar's.
    class DescriptorPool
      # @return [DescriptorPool] the pool generated code adds its files to
      def self.generated_pool
        @generated_pool
      end

      def initialize
        @schema_pool = Protostar::Schema::Pool.new
        @registry = Protostar::Types::Registry.new(open_enums: true)
        @wrappers = {}.compare_by_identity
        @serialized = {}
        @classes = {}.compare_by_identity
        @monitor = Monitor.new
      end

      # Builds a serialized FileDescriptorProto and defines its message
      # classes. Its dependencies must have been added first. Adding a file
      # of the same name again returns it when the bytes are the same.
      # @param serialized [String] a serialized google.protobuf.FileDescriptorProto
      # @return [FileDescriptor]
      # @raise [ArgumentError] when the bytes do not parse
      # @raise [TypeError] when the file does not build
      def add_serialized_file(serialized)
        raise ::TypeError, "wrong argument type #{serialized.class} (expected String)" unless serialized.is_a?(String)
        @monitor.synchronize do
          name = file_name(serialized)
          if (existing = @schema_pool.file(name))
            raise TypeError, "Unable to build file to DescriptorPool: duplicate file name #{name}" unless @serialized[name] == serialized.b
            return __wrap(existing)
          end
          file = begin
            Protostar::Schema::Proto.build(serialized, @schema_pool)
          rescue Protostar::DecodeError
            raise ArgumentError, "Unable to parse FileDescriptorProto"
          rescue Protostar::Error => e
            raise TypeError, "Unable to build file to DescriptorPool: #{e.message}"
          end
          begin
            @schema_pool.add(file)
          rescue Protostar::Error => e
            raise TypeError, "Unable to build file to DescriptorPool: #{e.message}"
          end
          @serialized[name] = serialized.b.freeze
          define(file)
          __wrap(file)
        end
      end

      # @param name [String] the full name of a message, enum, extension or
      #   service, or a file name
      # @return [Descriptor, EnumDescriptor, FieldDescriptor, ServiceDescriptor, FileDescriptor, nil]
      def lookup(name)
        found = @schema_pool.find_symbol(name)
        case found
        when Protostar::Schema::Message, Protostar::Schema::Enum, Protostar::Schema::Service
          __wrap(found)
        when Protostar::Schema::Field
          __wrap(found) if found.extension?
        when nil
          file = @schema_pool.file(name)
          file && __wrap(file)
        end
      end

      def inspect
        "#<#{self.class.name} #{@schema_pool.files.size} files>"
      end

      # @api private
      # @return [Protostar::Schema::Pool]
      def __schema_pool
        @schema_pool
      end

      # @api private
      # @return [Protostar::Types::Registry]
      def __registry
        @registry
      end

      # The wrapper of a schema descriptor, one per descriptor
      # @api private
      def __wrap(schema)
        @monitor.synchronize do
          @wrappers[schema] ||= wrapper_class(schema).__wrap(schema, self)
        end
      end

      # @api private
      # @return [Class, nil]
      def __msgclass(schema)
        @classes[schema]
      end

      private

      def wrapper_class(schema)
        case schema
        when Protostar::Schema::Message then Descriptor
        when Protostar::Schema::Field then FieldDescriptor
        when Protostar::Schema::Oneof then OneofDescriptor
        when Protostar::Schema::Enum then EnumDescriptor
        when Protostar::Schema::Service then ServiceDescriptor
        when Protostar::Schema::Method then MethodDescriptor
        when Protostar::Schema::File then FileDescriptor
        else raise ArgumentError, "not a descriptor: #{schema.class}"
        end
      end

      def file_name(serialized)
        r = Protostar::Wire::Reader.new(serialized)
        until r.eof?
          number, wire_type = r.read_tag
          return r.read_bytes.force_encoding(Encoding::UTF_8) if number == 1 && wire_type == Protostar::Wire::LENGTH_DELIMITED
          r.skip_field(number, wire_type)
        end
        ""
      rescue Protostar::DecodeError
        raise ArgumentError, "Unable to parse FileDescriptorProto"
      end

      def define(file)
        types = @registry.define(file)
        file.all_messages.each do |m|
          next if m.map_entry?
          klass = types.fetch(m.full_name)
          @classes[m] = klass
          Internal::MessageClass.setup(klass, __wrap(m))
        end
      end
    end
  end
end
