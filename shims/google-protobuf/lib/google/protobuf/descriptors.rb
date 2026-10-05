# frozen_string_literal: true

require "forwardable"

module Google
  module Protobuf
    module Internal
      # A descriptor hash without the json_names a .proto would not have
      # spelled out, as upb's to_proto gives them
      # @api private
      def self.without_json_names(hash)
        Protostar::Compiler::Emitters::GoogleRuby.without_json_names(hash)
      end

      # What every descriptor wrapper shares: a {Protostar::Schema} descriptor
      # and the DescriptorPool it belongs to. Methods the gem does not have are
      # passed to the schema descriptor, because protostar's runtime reads
      # `klass.descriptor` (here a wrapper) as a {Protostar::Schema::Message}.
      # @api private
      module Wrapper
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          def new(*)
            raise "Descriptor objects may not be created from Ruby."
          end

          # @api private
          def __wrap(schema, pool)
            instance = allocate
            instance.send(:initialize, schema, pool)
            instance
          end
        end

        # @return [DescriptorPool]
        attr_reader :descriptor_pool

        # @api private
        attr_reader :__schema

        def to_s
          inspect
        end

        def inspect
          "#{self.class.name}: #{name}"
        end

        private

        def initialize(schema, pool)
          @__schema = schema
          @descriptor_pool = pool
        end

        def wrap(schema)
          schema && @descriptor_pool.__wrap(schema)
        end

        # The descriptor's options as a google.protobuf.*Options message of
        # the generated pool, frozen, without `features` (as the gem gives them)
        def options_message(type)
          require "google/protobuf/descriptor_pb"
          options = @__schema.options
          hash = options.declared? ? options.__legacy_h : {}
          bytes = Protostar::Schema::Proto::HashCodec.encode(
            Protostar::Schema::Proto.schema(type), hash, @__schema.file.extension_finder(@descriptor_pool.__schema_pool)
          )
          message = Google::Protobuf.const_get(type).decode(bytes)
          message.clear_features if message.respond_to?(:clear_features)
          message.freeze
        end

        # The descriptor as a google.protobuf.*Proto message of the generated pool
        def proto_message(type, hash)
          require "google/protobuf/descriptor_pb"
          bytes = Protostar::Schema::Proto::HashCodec.encode(
            Protostar::Schema::Proto.schema(type), hash, @__schema.file.extension_finder(@descriptor_pool.__schema_pool)
          )
          Google::Protobuf.const_get(type).decode(bytes)
        end
      end
    end

    # A message type
    class Descriptor
      include Internal::Wrapper
      include Enumerable
      extend Forwardable

      # protostar's runtime reads `klass.descriptor` as a Protostar::Schema::Message
      # (JSON, text, Any); these are the methods it calls
      # @api private
      def_delegators :@__schema, :full_name, :file, :fields, :fields_by_name, :fields_by_number,
        :fields_by_json_name, :map_entry?, :message_set_wire_format?, :extension_number?

      # @return [String] the full name
      def name
        @__schema.full_name
      end

      def inspect
        "Descriptor - (not the message class) #{name}"
      end

      # @return [FileDescriptor]
      def file_descriptor
        wrap(@__schema.file)
      end

      # Yields each field, in declaration order
      # @yieldparam field [FieldDescriptor]
      def each
        return enum_for(:each) unless block_given?
        @__schema.fields.each { |f| yield wrap(f) }
        nil
      end

      # Yields each oneof, synthetic ones (proto3 `optional`) included
      # @yieldparam oneof [OneofDescriptor]
      def each_oneof
        return enum_for(:each_oneof) unless block_given?
        @__schema.oneofs.each { |o| yield wrap(o) }
        nil
      end

      # @param name [String]
      # @return [FieldDescriptor, nil]
      def lookup(name)
        wrap(@__schema.fields_by_name[name.to_s])
      end

      # @param name [String]
      # @return [OneofDescriptor, nil]
      def lookup_oneof(name)
        wrap(@__schema.oneofs.find { |o| o.name == name.to_s })
      end

      # @return [Class] the message class
      def msgclass
        @msgclass ||= @descriptor_pool.__msgclass(@__schema)
      end

      # @return [Google::Protobuf::MessageOptions] frozen
      def options
        @options ||= options_message(:MessageOptions)
      end

      # @return [Google::Protobuf::DescriptorProto]
      def to_proto
        @to_proto ||= proto_message(:DescriptorProto, Internal.without_json_names(@__schema.to_h))
      end

      # @api private
      def __msgclass=(klass)
        @msgclass = klass
      end

      private

      WRAPPERS = %w[DoubleValue FloatValue Int64Value UInt64Value Int32Value UInt32Value StringValue BytesValue BoolValue]
        .to_h { |n| ["google.protobuf.#{n}", true] }.freeze
      private_constant :WRAPPERS

      def wrapper?
        WRAPPERS.key?(name)
      end
    end

    # A field of a message, or an extension
    class FieldDescriptor
      include Internal::Wrapper

      # Field types as their C types: what RepeatedField and Map compare
      CTYPES = {
        int32: :int32, sint32: :int32, sfixed32: :int32, int64: :int64, sint64: :int64, sfixed64: :int64,
        uint32: :uint32, fixed32: :uint32, uint64: :uint64, fixed64: :uint64, float: :float, double: :double,
        bool: :bool, string: :string, bytes: :bytes, enum: :enum, message: :message, group: :message
      }.freeze

      # @return [String]
      def name
        @__schema.name
      end

      # @return [String]
      def json_name
        @__schema.json_name
      end

      # @return [Integer]
      def number
        @__schema.number
      end

      # @return [Symbol] :int32, :string, :message, :group and so on; map fields are :message
      def type
        @__schema.type
      end

      # @return [Symbol] :optional, :required or :repeated
      def label
        if @__schema.repeated? then :repeated
        elsif @__schema.required? then :required
        else :optional
        end
      end

      # @return [Object, nil] the default as the field's reader gives it; nil for messages
      def default
        return nil if sub_message?
        if repeated?
          Internal::Convert.zero(type, subtype)
        elsif type == :enum
          d = @__schema.default
          d.is_a?(Symbol) ? subtype.__names.fetch(subtype.__numbers.fetch(d)) : d
        else
          @__schema.default
        end
      end

      # @return [String, nil] the full name of the message or enum type
      def submsg_name
        sub = @__schema.message_type || @__schema.enum_type
        sub&.full_name
      end

      # @return [Descriptor, EnumDescriptor, nil] for message and enum fields;
      #   a map field's is its entry message
      def subtype
        return @subtype if defined?(@subtype)
        @subtype = wrap(@__schema.message_type || @__schema.enum_type)
      end

      def has_presence?
        @__schema.presence?
      end

      def is_packed?
        @__schema.packed?
      end

      def map?
        @__schema.map?
      end

      def required?
        @__schema.required?
      end

      def repeated?
        @__schema.repeated?
      end

      def sub_message?
        type == :message || type == :group
      end

      def wrapper?
        sub = subtype
        sub.is_a?(Descriptor) && sub.send(:wrapper?)
      end

      # @param msg [Message]
      # @return [Object] the field's value on the message
      # @raise [TypeError] when the message is not of the field's message type
      def get(msg)
        check_owner(msg, "get")
        msg.__gget(self)
      end

      # Sets the field, with the checks its writer makes
      def set(msg, value)
        check_owner(msg, "set")
        msg.__gset(self, value)
        nil
      end

      # @raise [ArgumentError] when the field does not track presence
      def has?(msg)
        check_owner(msg, "has")
        raise ArgumentError, "does not track presence" unless has_presence?
        msg.__ghas?(self)
      end

      def clear(msg)
        check_owner(msg, "clear")
        msg.__gclear(self)
        nil
      end

      # @return [Google::Protobuf::FieldOptions] frozen
      def options
        @options ||= options_message(:FieldOptions)
      end

      # @return [Google::Protobuf::FieldDescriptorProto]
      def to_proto
        @to_proto ||= proto_message(:FieldDescriptorProto, Internal.without_json_names({field: [@__schema.to_h]})[:field][0])
      end

      # @api private
      # @return [Protostar::Message::FieldInfo, nil] nil for extensions
      def __info
        return @__info if defined?(@__info)
        @__info = if @__schema.extension?
          nil
        else
          wrap(@__schema.containing_message).msgclass.__by_number[number]
        end
      end

      # @api private
      def __ctype
        CTYPES.fetch(type)
      end

      # @api private
      def __extension?
        @__schema.extension?
      end

      # @api private
      # @return [Descriptor] the message the field belongs to (an extension's extendee)
      def __owner
        @__owner ||= wrap(@__schema.extension? ? @__schema.extendee : @__schema.containing_message)
      end

      private

      def check_owner(msg, verb)
        return if msg.class.respond_to?(:descriptor) && msg.class.descriptor.equal?(__owner)
        raise TypeError, "#{verb} method called on wrong message type"
      end
    end

    # A oneof of a message
    class OneofDescriptor
      include Internal::Wrapper
      include Enumerable

      def name
        @__schema.name
      end

      # @yieldparam field [FieldDescriptor]
      def each
        return enum_for(:each) unless block_given?
        @__schema.fields.each { |f| yield wrap(f) }
        nil
      end

      # @return [Google::Protobuf::OneofOptions] frozen
      def options
        @options ||= options_message(:OneofOptions)
      end

      # @return [Google::Protobuf::OneofDescriptorProto]
      def to_proto
        @to_proto ||= proto_message(:OneofDescriptorProto, @__schema.to_h)
      end
    end

    # An enum type
    class EnumDescriptor
      include Internal::Wrapper
      include Enumerable

      # @return [String] the full name
      def name
        @__schema.full_name
      end

      # @return [FileDescriptor]
      def file_descriptor
        wrap(@__schema.file)
      end

      # @param name [String, Symbol]
      # @return [Integer, nil]
      def lookup_name(name)
        __numbers[name.to_sym]
      end

      # @param number [Integer]
      # @return [Symbol, nil] the first name declared for the number
      def lookup_value(number)
        __names[number]
      end

      # Yields every value, aliases included
      # @yieldparam name [Symbol]
      # @yieldparam number [Integer]
      def each
        return enum_for(:each) unless block_given?
        @__schema.values.each { |v| yield v.name.to_sym, v.number }
        nil
      end

      # @return [false] the gem treats every enum as open, whatever the .proto says
      def is_closed?
        false
      end

      # @return [Module] the enum module: a constant per value, `lookup`, `resolve`, `descriptor`
      def enummodule
        @enummodule ||= build_module
      end

      # @return [Google::Protobuf::EnumOptions] frozen
      def options
        @options ||= options_message(:EnumOptions)
      end

      # @return [Google::Protobuf::EnumDescriptorProto]
      def to_proto
        @to_proto ||= proto_message(:EnumDescriptorProto, @__schema.to_h)
      end

      # @api private
      # @return [Hash{Integer => Symbol}] number to its first name
      def __names
        @__names ||= @__schema.values.each_with_object({}) { |v, h| h[v.number] ||= v.name.to_sym }.freeze
      end

      # @api private
      # @return [Hash{Symbol => Integer}] every name to its number
      def __numbers
        @__numbers ||= @__schema.values.to_h { |v| [v.name.to_sym, v.number] }.freeze
      end

      private

      def build_module
        descriptor = self
        mod = Module.new
        mod.instance_variable_set(:@descriptor, descriptor)
        mod.extend(Internal::EnumModule)
        @__schema.values.each do |v|
          const = v.name
          if const.match?(/\A[a-z]/)
            const = const[0].upcase + const[1..]
          elsif !const.match?(/\A[A-Z]/)
            warn("Enum value '#{v.name}' does not start with an uppercase letter as is required for Ruby constants.")
            next
          end
          mod.const_set(const, v.number) unless mod.const_defined?(const, false)
        end
        mod
      end
    end

    module Internal
      # Extended by every enum module
      # @api private
      module EnumModule
        # @return [EnumDescriptor]
        attr_reader :descriptor

        # @return [Symbol, nil]
        def lookup(number)
          @descriptor.lookup_value(number)
        end

        # @return [Integer, nil]
        def resolve(name)
          @descriptor.lookup_name(name)
        end
      end
    end

    # A service
    class ServiceDescriptor
      include Internal::Wrapper
      include Enumerable

      # @return [String] the full name
      def name
        @__schema.full_name
      end

      # @return [FileDescriptor]
      def file_descriptor
        wrap(@__schema.file)
      end

      # @yieldparam method [MethodDescriptor]
      def each
        return enum_for(:each) unless block_given?
        @__schema.rpcs.each { |m| yield wrap(m) }
        nil
      end

      # @return [Google::Protobuf::ServiceOptions] frozen
      def options
        @options ||= options_message(:ServiceOptions)
      end

      # @return [Google::Protobuf::ServiceDescriptorProto]
      def to_proto
        @to_proto ||= proto_message(:ServiceDescriptorProto, @__schema.to_h)
      end
    end

    # A method of a service
    class MethodDescriptor
      include Internal::Wrapper

      def name
        @__schema.name
      end

      # @return [Descriptor]
      def input_type
        wrap(@__schema.input_type)
      end

      # @return [Descriptor]
      def output_type
        wrap(@__schema.output_type)
      end

      def client_streaming
        @__schema.client_streaming?
      end

      def server_streaming
        @__schema.server_streaming?
      end

      # @return [Google::Protobuf::MethodOptions] frozen
      def options
        @options ||= options_message(:MethodOptions)
      end

      # @return [Google::Protobuf::MethodDescriptorProto]
      def to_proto
        @to_proto ||= proto_message(:MethodDescriptorProto, @__schema.to_h)
      end
    end

    # A .proto file
    class FileDescriptor
      include Internal::Wrapper

      def name
        @__schema.name
      end

      # @return [Google::Protobuf::FileOptions] frozen
      def options
        @options ||= options_message(:FileOptions)
      end

      # @return [Google::Protobuf::FileDescriptorProto]
      def to_proto
        @to_proto ||= begin
          require "google/protobuf/descriptor_pb"
          Google::Protobuf::FileDescriptorProto.decode(
            Protostar::Compiler::Emitters::GoogleRuby.serialized(@__schema, @descriptor_pool.__schema_pool)
          )
        end
      end
    end
  end
end
