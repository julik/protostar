# frozen_string_literal: true

module Protostar
  module Schema
    # An RPC service. Its methods are exposed as #rpcs and #rpc so that
    # Object#methods and Object#method keep working on a descriptor.
    class Service < Descriptor
      attr_reader :file #: File

      def initialize(name:, full_name:, file:, index:) # :nodoc:
        @name = name
        @full_name = full_name
        @file = file
        @index = index
        @rpcs = Freezer::EMPTY_ARRAY
        @rpcs_by_name = Freezer::EMPTY_HASH
      end

      def __rpcs(rpcs) # :nodoc:
        @rpcs = rpcs
        @rpcs_by_name = rpcs.to_h { |m| [m.name, m] }.freeze
        self
      end

      # Declaration order.
      attr_reader :rpcs #: Array[Method]

      #: ((String | Symbol) name) -> Method?
      def rpc(name)
        @rpcs_by_name[name.to_s]
      end

      #: () -> Protostar::Google::Protobuf::ServiceDescriptorProto
      def to_proto
        Proto::Writer.service(self)
      end
    end

    # One RPC of a Service
    class Method < Descriptor
      attr_reader :service #: Service
      attr_reader :input_type #: Message
      attr_reader :output_type #: Message

      attr_reader :input_type_name, :output_type_name # :nodoc:

      def initialize(name:, full_name:, service:, index:, input_type_name:, output_type_name:, # :nodoc:
        client_streaming:, server_streaming:)
        @name = name
        @full_name = full_name
        @service = service
        @index = index
        @input_type_name = input_type_name
        @output_type_name = output_type_name
        @client_streaming = client_streaming
        @server_streaming = server_streaming
      end

      #: () -> File
      def file
        @service.file
      end

      #: () -> bool
      def client_streaming?
        @client_streaming
      end

      #: () -> bool
      def server_streaming?
        @server_streaming
      end

      #: () -> Protostar::Google::Protobuf::MethodDescriptorProto
      def to_proto
        Proto::Writer.rpc(self)
      end
    end
  end
end
