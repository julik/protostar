# frozen_string_literal: true

require "protostar"
require "protostar/google/protobuf/compiler/plugin_pb"

module Protostar
  # `protoc-gen-protostar`: a protoc plugin writing the same files as
  # `protostar compile`. The parameter selects the outputs, comma-separated:
  # `ruby` (protostar's native Ruby, the default), `google` (protoc's
  # google-protobuf Ruby), `rbs`, `rbi` and `grpc`. `ruby` brings its RBS and
  # RBI along unless the parameter also says `no-rbs` or `no-rbi`.
  #
  # ```sh
  # protoc --plugin=protoc-gen-protostar --protostar_out=ruby,grpc:lib acme/service.proto
  # ```
  module Plugin
    Compiler = Protostar::Compiler
    Emitters = Compiler::Emitters
    Request = Protostar::Google::Protobuf::Compiler::CodeGeneratorRequest
    Response = Protostar::Google::Protobuf::Compiler::CodeGeneratorResponse
    Feature = Response::Feature
    OUTPUTS = %w[ruby google rbs rbi grpc].freeze
    # Parameters that turn off an output `ruby` brings along
    DECLINE = %w[no-rbs no-rbi].freeze

    module_function

    # Reads a CodeGeneratorRequest from `input` and writes the response to `output`
    def run(input = $stdin, output = $stdout)
      input.binmode
      output.binmode
      output.write(respond(input.read))
      output.flush
      0
    end

    # - `bytes`: a serialized CodeGeneratorRequest
    #
    # Returns a serialized CodeGeneratorResponse.
    #: (String bytes) -> String
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

    # Returns file name to content.
    #: (Protostar::Google::Protobuf::Compiler::CodeGeneratorRequest request) -> Hash[String, String]
    def generate(request)
      parameters = request.parameter.split(",").map(&:strip).reject(&:empty?)
      unknown = parameters - OUTPUTS - DECLINE
      unless unknown.empty?
        raise Protostar::Error, "unknown output #{unknown.first.inspect}; use #{(OUTPUTS + DECLINE).join(", ")}"
      end
      outputs = parameters - DECLINE
      outputs = ["ruby"] if outputs.empty?
      if outputs.include?("ruby") && outputs.include?("google")
        raise Protostar::Error, "ruby and google both write *_pb.rb; ask for one of them"
      end
      %w[rbs rbi].each do |kind|
        declined = parameters.include?("no-#{kind}")
        raise Protostar::Error, "#{kind} and no-#{kind} contradict each other" if declined && outputs.include?(kind)
        outputs += [kind] if outputs.include?("ruby") && !declined && !outputs.include?(kind)
      end
      pool = Schema::Pool.new
      # protoc has already warned about extension numbers used twice
      request.proto_file.each { |proto| pool.add(Schema::File.from_proto(proto, pool: pool), warn: false) }
      files = request.file_to_generate.map do |name|
        pool.file(name) || raise(Protostar::Error, "#{name} is not among the request's proto files")
      end
      generated = {}
      outputs.each do |output|
        files.each do |file|
          if output == "rbs" && file.syntax == :editions && !outputs.include?("ruby")
            raise Protostar::Error, "#{file.name}: #{CLI::RBS_EDITIONS}"
          end
          begin
            generated.merge!(emitter(output, pool, outputs).emit([file]))
          rescue Emitters::Error => e
            raise Protostar::Error, "#{file.name}: #{e.message}"
          end
        end
      end
      generated
    end

    def emitter(output, pool, outputs)
      case output
      when "ruby" then Emitters::Ruby.new
      when "google" then Emitters::GoogleRuby.new(pool: pool)
      when "rbs" then outputs.include?("ruby") ? Emitters::ProtostarRbs.new : Emitters::Rbs.new
      when "rbi" then outputs.include?("ruby") ? Emitters::ProtostarRbi.new : Emitters::Rbi.new
      when "grpc" then Emitters::Grpc.new
      end
    end
  end
end

require "protostar/cli"
