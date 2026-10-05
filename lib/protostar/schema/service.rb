# frozen_string_literal: true

module Protostar
  module Schema
    # An RPC service. Note that {#methods} and {#method} are the service's RPCs,
    # shadowing Object#methods and Object#method.
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
      def __methods(methods)
        @methods = methods
        @methods_by_name = methods.to_h { |m| [m.name, m] }.freeze
        self
      end

      # @return [Array<Method>] declaration order
      def methods(*)
        @methods
      end

      # @param name [String, Symbol]
      # @return [Method, nil]
      def method(name)
        @methods_by_name[name.to_s]
      end

      # @return [Hash] the ServiceDescriptorProto hash
      def to_h
        h = {name: @name}
        h[:method] = @methods.map(&:to_h) unless @methods.empty?
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
