# frozen_string_literal: true

# The program protobuf's conformance_test_runner talks to. It reads
# ConformanceRequests from stdin, each preceded by its length as a
# little-endian uint32, and answers each with a ConformanceResponse framed the
# same way, until stdin ends. Nothing but responses goes to stdout.
#
# conformance_cpp.cc in protobuf's conformance/ directory is the model.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("generated", __dir__))

require "protostar"
require "conformance/conformance_pb"
require "google/protobuf/test_messages_proto2_pb"
require "google/protobuf/test_messages_proto3_pb"
require "conformance/test_protos/test_messages_edition2023_pb"
require "conformance/test_protos/test_messages_edition_unstable_pb"
require "editions/golden/test_messages_proto2_editions_pb"
require "editions/golden/test_messages_proto3_editions_pb"

module ProtostarConformance
  # Serves the runner over stdin and stdout, logging to stderr.
  def self.main
    $stdin.binmode
    $stdout.binmode
    testee = Testee.new($stdin, $stdout)
    testee.run
    warn "protostar testee: input ended after #{testee.count} requests"
  end

  # Answers conformance requests over a pair of IOs
  class Testee
    Request = ::Conformance::ConformanceRequest
    Response = ::Conformance::ConformanceResponse

    # Errors that mean the payload is not a valid message of the requested type
    PARSE_ERRORS = [Protostar::Error, Protostar::TypeError, RangeError, EncodingError].freeze
    # Errors that mean the message has no form in the requested output format
    SERIALIZE_ERRORS = [Protostar::Error, Protostar::TypeError, RangeError, EncodingError].freeze

    # @return [Integer] how many requests were answered
    attr_reader :count

    # @param input [IO] where requests come from
    # @param output [IO] where responses go
    # @param registry [Protostar::Types::Registry] where message types are looked up
    def initialize(input, output, registry: Protostar::Types.registry)
      @input = input
      @output = output
      @registry = registry
      @count = 0
    end

    # Answers requests until the input ends.
    # @return [Integer] how many requests were answered
    # @raise [IOError] when the input ends inside a request
    def run
      while (request = read_request)
        write_response(handle(request))
        @count += 1
      end
      @count
    end

    # @param request [Conformance::ConformanceRequest]
    # @return [Conformance::ConformanceResponse]
    def handle(request)
      klass = @registry.find(request.message_type)
      return Response.new(runtime_error: "No such message type: #{request.message_type}") unless klass.is_a?(Class)

      message = begin
        parse(klass, request)
      rescue *PARSE_ERRORS => e
        return Response.new(parse_error: "#{e.class}: #{e.message}".scrub)
      end
      return message if message.is_a?(Response)

      begin
        serialize(message, request)
      rescue *SERIALIZE_ERRORS => e
        Response.new(serialize_error: "#{e.class}: #{e.message}".scrub)
      end
    rescue => e
      Response.new(runtime_error: "#{e.class}: #{e.message}".scrub)
    end

    private

    def parse(klass, request)
      case request.which_payload
      when :protobuf_payload
        klass.decode(request.protobuf_payload)
      when :json_payload
        ignore = request.test_category == :JSON_IGNORE_UNKNOWN_PARSING_TEST
        klass.decode_json(request.json_payload, ignore_unknown_fields: ignore, registry: @registry)
      when :text_payload
        Protostar::Text.parse(klass, request.text_payload, registry: @registry)
      when :jspb_payload
        Response.new(skipped: "JSPB is not supported")
      else
        raise ArgumentError, "request has no payload"
      end
    end

    def serialize(message, request)
      case request.requested_output_format
      when :PROTOBUF
        Response.new(protobuf_payload: message.encode)
      when :JSON
        Response.new(json_payload: Protostar::JSON.encode(message, registry: @registry))
      when :TEXT_FORMAT
        text = Protostar::Text.print(message, unknown_fields: request.print_unknown_fields, registry: @registry)
        Response.new(text_payload: text)
      when :JSPB
        Response.new(skipped: "JSPB is not supported")
      else
        raise ArgumentError, "unsupported output format #{request.requested_output_format.inspect}"
      end
    end

    def read_request
      header = @input.read(4)
      return nil if header.nil?
      raise IOError, "truncated length prefix" if header.bytesize < 4
      length = header.unpack1("V")
      body = length.zero? ? +"" : @input.read(length)
      raise IOError, "truncated request: wanted #{length} bytes" if body.nil? || body.bytesize < length
      Request.decode(body)
    end

    def write_response(response)
      bytes = response.encode
      @output.write([bytes.bytesize].pack("V"), bytes)
      @output.flush
    end
  end
end
