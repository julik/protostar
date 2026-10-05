# frozen_string_literal: true

require "protostar"
require "protostar/google/protobuf/compiler/plugin_pb"

module Protostar
  # `protoc-gen-protostar`: a protoc plugin writing the same files as
  # `protostar compile`. The parameter selects the outputs, comma-separated:
  # `ruby` (protostar's native Ruby, the default), `google` (protoc's
  # google-protobuf Ruby), `rbs` and `grpc`.
  #
  #   protoc --plugin=protoc-gen-protostar --protostar_out=ruby,grpc:lib acme/service.proto
  module Plugin
    Compiler = Protostar::Compiler
    Emitters = Compiler::Emitters
    Request = Protostar::Google::Protobuf::Compiler::CodeGeneratorRequest
    Response = Protostar::Google::Protobuf::Compiler::CodeGeneratorResponse
    Feature = Response::Feature
    OUTPUTS = %w[ruby google rbs grpc].freeze

    module_function

    # Reads a CodeGeneratorRequest from `input` and writes the response to `output`
    def run(input = $stdin, output = $stdout)
      input.binmode
      output.binmode
      output.write(respond(input.read))
      output.flush
      0
    end

    # @param bytes [String] a serialized CodeGeneratorRequest
    # @return [String] a serialized CodeGeneratorResponse
    def respond(bytes)
      response = Response.new(
        supported_features: Feature::FEATURE_PROTO3_OPTIONAL | Feature::FEATURE_SUPPORTS_EDITIONS,
        minimum_edition: Schema::Features::EDITIONS[:EDITION_PROTO2],
        maximum_edition: Schema::Features::EDITIONS[:EDITION_2024]
      )
      begin
        generate(Request.decode(bytes)).each do |name, content|
          response.file << Response::File.new(name: name, content: content)
        end
      rescue Protostar::Error => e
        response.error = e.message
        response.file.clear
      end
      response.encode
    end

    # @param request [Request]
    # @return [Hash{String => String}] file name to content
    def generate(request)
      outputs = request.parameter.split(",").map(&:strip).reject(&:empty?)
      outputs = ["ruby"] if outputs.empty?
      unknown = outputs - OUTPUTS
      raise Protostar::Error, "unknown output #{unknown.first.inspect}; use #{OUTPUTS.join(", ")}" unless unknown.empty?
      if outputs.include?("ruby") && outputs.include?("google")
        raise Protostar::Error, "ruby and google both write *_pb.rb; ask for one of them"
      end
      pool = Schema::Pool.new
      request.proto_file.each { |proto| pool.add(Schema::Builder.from_proto(proto, pool: pool)) }
      files = request.file_to_generate.map do |name|
        pool.file(name) || raise(Protostar::Error, "#{name} is not among the request's proto files")
      end
      generated = {}
      outputs.each do |output|
        files.each do |file|
          if output == "rbs" && file.syntax == :editions
            raise Protostar::Error, "#{file.name}: #{CLI::RBS_EDITIONS}"
          end
          begin
            generated.merge!(emitter(output, pool).emit([file]))
          rescue Emitters::Error => e
            raise Protostar::Error, "#{file.name}: #{e.message}"
          end
        end
      end
      generated
    end

    def emitter(output, pool)
      case output
      when "ruby" then Emitters::Ruby.new
      when "google" then Emitters::GoogleRuby.new(pool: pool)
      when "rbs" then Emitters::Rbs.new
      when "grpc" then Emitters::Grpc.new
      end
    end
  end
end

require "protostar/cli"
