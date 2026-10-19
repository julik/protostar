# frozen_string_literal: true

require "forwardable"

module Google
  module Protobuf
    module Internal
      # What every descriptor wrapper shares: a Protostar::Schema descriptor
      # and the DescriptorPool it belongs to. Methods the gem does not have are
      # passed to the schema descriptor, because protostar's runtime reads
      # `klass.descriptor` (here a wrapper) as a Protostar::Schema::Message.
      module Wrapper # :nodoc: all
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          def new(*)
            raise "Descriptor objects may not be created from Ruby."
          end

          def __wrap(schema, pool) # :nodoc:
            instance = allocate
            instance.send(:initialize, schema, pool)
            instance
          end
        end

        attr_reader :descriptor_pool #: DescriptorPool

        attr_reader :__schema # :nodoc:

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
          options = @__schema.options
          bytes = options.declared? ? options.to_proto.encode : ""
          message = Google::Protobuf.const_get(type).decode(bytes)
          message.clear_features if message.respond_to?(:clear_features)
          message.freeze
        end

        # The descriptor as a google.protobuf.*Proto message of the generated
        # pool, with json_names only where a .proto would have spelled them
        # out, as upb's to_proto gives them
        def proto_message(type, proto)
          Google::Protobuf.const_get(type).decode(proto.encode)
        end
      end
    end

    # A message type
    class Descriptor
      include Internal::Wrapper
      include Enumerable #[untyped]
      extend Forwardable

      # protostar's runtime reads `klass.descriptor` as a Protostar::Schema::Message
      # (JSON, text, Any); these are the methods it calls
      def_delegators :@__schema, :full_name, :file, :fields, :fields_by_name, :fields_by_number,
        :fields_by_json_name, :map_entry?, :message_set_wire_format?, :extension_number?

      # Returns the full name.
      #: () -> String
      def name
        @__schema.full_name
      end

      def inspect
        "Descriptor - (not the message class) #{name}"
      end

      #: () -> FileDescriptor
      def file_descriptor
        wrap(@__schema.file)
      end

      # Yields each field, in declaration order
      #: () ?{ (FieldDescriptor field) -> untyped } -> untyped
      def each
        return enum_for(:each) unless block_given?
        @__schema.fields.each { |f| yield wrap(f) }
        nil
      end

      # Yields each oneof, synthetic ones (proto3 `optional`) included
      #: () ?{ (OneofDescriptor oneof) -> untyped } -> untyped
      def each_oneof
        return enum_for(:each_oneof) unless block_given?
        @__schema.oneofs.each { |o| yield wrap(o) }
        nil
      end

      #: (String name) -> FieldDescriptor?
      def lookup(name)
        wrap(@__schema.fields_by_name[name.to_s])
      end

      #: (String name) -> OneofDescriptor?
      def lookup_oneof(name)
        wrap(@__schema.oneofs.find { |o| o.name == name.to_s })
      end

      # Returns the message class.
      #: () -> Class
      def msgclass
        @msgclass ||= @descriptor_pool.__msgclass(@__schema)
      end

      # Returns frozen.
      #: () -> Google::Protobuf::MessageOptions
      def options
        @options ||= options_message(:MessageOptions)
      end

      #: () -> Google::Protobuf::DescriptorProto
      def to_proto
        @to_proto ||= proto_message(:DescriptorProto, @__schema.to_proto(default_json_names: false))
      end

      def __msgclass=(klass) # :nodoc:
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

      #: () -> String
      def name
        @__schema.name
      end

      #: () -> String
      def json_name
        @__schema.json_name
      end

      #: () -> Integer
      def number
        @__schema.number
      end

      # Returns :int32, :string, :message, :group and so on; map fields are :message.
      #: () -> Symbol
      def type
        @__schema.type
      end

      # Returns :optional, :required or :repeated.
      #: () -> Symbol
      def label
        if @__schema.repeated? then :repeated
        elsif @__schema.required? then :required
        else :optional
        end
      end

      # Returns the default as the field's reader gives it; nil for messages.
      #: () -> untyped
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

      # Returns the full name of the message or enum type.
      #: () -> String?
      def submsg_name
        sub = @__schema.message_type || @__schema.enum_type
        sub&.full_name
      end

      # Returns for message and enum fields;
      # a map field's is its entry message.
      #: () -> (Descriptor | EnumDescriptor)?
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

      # Returns the field's value on the message.
      # Raises TypeError when the message is not of the field's message type.
      #: (Protostar::Message msg) -> untyped
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

      # Raises ArgumentError when the field does not track presence.
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

      # Returns frozen.
      #: () -> Google::Protobuf::FieldOptions
      def options
        @options ||= options_message(:FieldOptions)
      end

      #: () -> Google::Protobuf::FieldDescriptorProto
      def to_proto
        @to_proto ||= proto_message(:FieldDescriptorProto, @__schema.to_proto(default_json_names: false))
      end

      # Returns nil for extensions.
      #: () -> Protostar::Message::FieldInfo?
      def __info # :nodoc:
        return @__info if defined?(@__info)
        @__info = if @__schema.extension?
          nil
        else
          wrap(@__schema.containing_message).msgclass.__by_number[number]
        end
      end

      def __ctype # :nodoc:
        CTYPES.fetch(type)
      end

      def __extension? # :nodoc:
        @__schema.extension?
      end

      # Returns the message the field belongs to (an extension's extendee).
      #: () -> Descriptor
      def __owner # :nodoc:
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
      include Enumerable #[untyped]

      def name
        @__schema.name
      end

      #: () ?{ (FieldDescriptor field) -> untyped } -> untyped
      def each
        return enum_for(:each) unless block_given?
        @__schema.fields.each { |f| yield wrap(f) }
        nil
      end

      # Returns frozen.
      #: () -> Google::Protobuf::OneofOptions
      def options
        @options ||= options_message(:OneofOptions)
      end

      #: () -> Google::Protobuf::OneofDescriptorProto
      def to_proto
        @to_proto ||= proto_message(:OneofDescriptorProto, @__schema.to_proto)
      end
    end

    # An enum type
    class EnumDescriptor
      include Internal::Wrapper
      include Enumerable #[untyped]

      # Returns the full name.
      #: () -> String
      def name
        @__schema.full_name
      end

      #: () -> FileDescriptor
      def file_descriptor
        wrap(@__schema.file)
      end

      #: ((String | Symbol) name) -> Integer?
      def lookup_name(name)
        __numbers[name.to_sym]
      end

      # Returns the first name declared for the number.
      #: (Integer number) -> Symbol?
      def lookup_value(number)
        __names[number]
      end

      # Yields every value, aliases included
      #: () ?{ (Symbol name, Integer number) -> untyped } -> untyped
      def each
        return enum_for(:each) unless block_given?
        @__schema.values.each { |v| yield v.name.to_sym, v.number }
        nil
      end

      # Returns the gem treats every enum as open, whatever the .proto says.
      #: () -> bool
      def is_closed?
        false
      end

      # Returns the enum module: a constant per value, `lookup`, `resolve`, `descriptor`.
      #: () -> Module
      def enummodule
        @enummodule ||= build_module
      end

      # Returns frozen.
      #: () -> Google::Protobuf::EnumOptions
      def options
        @options ||= options_message(:EnumOptions)
      end

      #: () -> Google::Protobuf::EnumDescriptorProto
      def to_proto
        @to_proto ||= proto_message(:EnumDescriptorProto, @__schema.to_proto)
      end

      # Returns number to its first name.
      #: () -> Hash[Integer, Symbol]
      def __names # :nodoc:
        @__names ||= @__schema.values.each_with_object({}) { |v, h| h[v.number] ||= v.name.to_sym }.freeze
      end

      # Returns every name to its number.
      #: () -> Hash[Symbol, Integer]
      def __numbers # :nodoc:
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
      module EnumModule # :nodoc: all
        attr_reader :descriptor #: EnumDescriptor

        #: (untyped number) -> Symbol?
        def lookup(number)
          @descriptor.lookup_value(number)
        end

        #: (untyped name) -> Integer?
        def resolve(name)
          @descriptor.lookup_name(name)
        end
      end
    end

    # A service
    class ServiceDescriptor
      include Internal::Wrapper
      include Enumerable #[untyped]

      # Returns the full name.
      #: () -> String
      def name
        @__schema.full_name
      end

      #: () -> FileDescriptor
      def file_descriptor
        wrap(@__schema.file)
      end

      #: () ?{ (MethodDescriptor method) -> untyped } -> untyped
      def each
        return enum_for(:each) unless block_given?
        @__schema.rpcs.each { |m| yield wrap(m) }
        nil
      end

      # Returns frozen.
      #: () -> Google::Protobuf::ServiceOptions
      def options
        @options ||= options_message(:ServiceOptions)
      end

      #: () -> Google::Protobuf::ServiceDescriptorProto
      def to_proto
        @to_proto ||= proto_message(:ServiceDescriptorProto, @__schema.to_proto)
      end
    end

    # A method of a service
    class MethodDescriptor
      include Internal::Wrapper

      def name
        @__schema.name
      end

      #: () -> Descriptor
      def input_type
        wrap(@__schema.input_type)
      end

      #: () -> Descriptor
      def output_type
        wrap(@__schema.output_type)
      end

      def client_streaming
        @__schema.client_streaming?
      end

      def server_streaming
        @__schema.server_streaming?
      end

      # Returns frozen.
      #: () -> Google::Protobuf::MethodOptions
      def options
        @options ||= options_message(:MethodOptions)
      end

      #: () -> Google::Protobuf::MethodDescriptorProto
      def to_proto
        @to_proto ||= proto_message(:MethodDescriptorProto, @__schema.to_proto)
      end
    end

    # A .proto file
    class FileDescriptor
      include Internal::Wrapper

      def name
        @__schema.name
      end

      # Returns frozen.
      #: () -> Google::Protobuf::FileOptions
      def options
        @options ||= options_message(:FileOptions)
      end

      #: () -> Google::Protobuf::FileDescriptorProto
      def to_proto
        @to_proto ||= Google::Protobuf::FileDescriptorProto.decode(
          Protostar::Compiler::Emitters::GoogleRuby.serialized(@__schema)
        )
      end
    end
  end
end
