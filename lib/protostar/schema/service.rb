# frozen_string_literal: true

module Protostar
  module Schema
    # An RPC service. Its methods are exposed as {#rpcs} and {#rpc} so that
    # Object#methods and Object#method keep working on a descriptor.
    class Service < Descriptor
      # @return [File]
      attr_reader :file

      # @api private
      def initialize(name:, full_name:, file:, index:, options:)
        @name = name
        @full_name = full_name
        @file = file
        @index = index
        @options = options
      end

      # @api private
      def __rpcs(rpcs)
        @rpcs = rpcs
        @rpcs_by_name = rpcs.to_h { |m| [m.name, m] }.freeze
        self
      end

      # @return [Array<Method>] declaration order
      attr_reader :rpcs

      # @param name [String, Symbol]
      # @return [Method, nil]
      def rpc(name)
        @rpcs_by_name[name.to_s]
      end

      # @return [Hash] the ServiceDescriptorProto hash
      def to_h
        h = {name: @name}
        h[:method] = @rpcs.map(&:to_h) unless @rpcs.empty?
        options_to_h(h)
      end
    end

    # One RPC of a {Service}
    class Method < Descriptor
      # @return [Service]
      attr_reader :service
      # @return [Message]
      attr_reader :input_type
      # @return [Message]
      attr_reader :output_type

      # @api private
      attr_reader :input_type_name, :output_type_name

      # @api private
      def initialize(name:, full_name:, service:, index:, options:, input_type_name:, output_type_name:,
        client_streaming:, server_streaming:)
        @name = name
        @full_name = full_name
        @service = service
        @index = index
        @options = options
        @input_type_name = input_type_name
        @output_type_name = output_type_name
        @client_streaming = client_streaming
        @server_streaming = server_streaming
      end

      # @return [File]
      def file
        @service.file
      end

      # @return [Boolean]
      def client_streaming?
        @client_streaming
      end

      # @return [Boolean]
      def server_streaming?
        @server_streaming
      end

      # @return [Hash] the MethodDescriptorProto hash
      def to_h
        h = {name: @name, input_type: ".#{@input_type.full_name}", output_type: ".#{@output_type.full_name}"}
        options_to_h(h)
        h[:client_streaming] = true if @client_streaming
        h[:server_streaming] = true if @server_streaming
        h
      end
    end
  end
end
