# frozen_string_literal: true

require "test/unit"
$LOAD_PATH.unshift(File.join(__dir__, "generated"))
require "grpc"
require "grpc/google_rpc_status_utils"
require "google/rpc/status_pb"
require "google/protobuf/well_known_types"
require "echo_services_pb"

# A real grpc server and client in this process, over a local port, with
# messages from Google-format files that protostar's compiler wrote
class GrpcTest < Test::Unit::TestCase
  Echo = Shimtest::Echo

  class EchoService < Echo::Echo::Service
    def say(request, _call)
      if request.text == "fail"
        status = Google::Rpc::Status.new(
          code: GRPC::Core::StatusCodes::INVALID_ARGUMENT,
          message: "no",
          details: [Google::Protobuf::Any.pack(Echo::EchoReply.new(text: "why", index: 7))]
        )
        raise GRPC::InvalidArgument.new("no", "grpc-status-details-bin" => Google::Rpc::Status.encode(status))
      end
      reply(request, 0)
    end

    def collect(call)
      texts = []
      call.each_remote_read { |request| texts << request.text }
      Echo::EchoReply.new(text: texts.join(","), index: texts.size)
    end

    def repeat(request, _call)
      Array.new(request.times) { |i| reply(request, i) }.each
    end

    def chat(requests, _call)
      requests.lazy.map { |request| Echo::EchoReply.new(text: request.text.upcase, index: request.times) }
    end

    def ping(empty, _call)
      empty
    end

    private

    def reply(request, index)
      Echo::EchoReply.new(
        text: request.text, index: index, sent_at: request.sent_at,
        tags: request.tags.to_h, attachments: request.attachments.to_a
      )
    end
  end

  class << self
    attr_reader :server, :stub

    def startup
      @server = GRPC::RpcServer.new(pool_size: 4)
      port = @server.add_http2_port("127.0.0.1:0", :this_port_is_insecure)
      @server.handle(EchoService)
      @thread = Thread.new { @server.run_till_terminated }
      @server.wait_till_running(10)
      @stub = Echo::Echo::Stub.new("127.0.0.1:#{port}", :this_channel_is_insecure, timeout: 10)
    end

    def shutdown
      @server&.stop
      @thread&.join(10)
    end
  end

  def stub
    self.class.stub
  end

  def test_the_implementation_is_protostar
    assert_equal :PROTOSTAR, Google::Protobuf::IMPLEMENTATION
    spec = Gem.loaded_specs.fetch("google-protobuf")
    assert_equal File.expand_path("../..", __dir__), spec.full_gem_path
    native = $LOADED_FEATURES.grep(/protobuf_c\b|protobuf_java|ffi[-_]compiler|\/ffi\.(rb|bundle|so)\z/)
    assert_empty native
    refute defined?(::FFI), "FFI is loaded"
    refute defined?(Google::Protobuf::Internal::ObjectCache)
  end

  def test_unary
    sent_at = Google::Protobuf::Timestamp.from_time(Time.at(1_700_000_000, 123_456_789, :nsec))
    attachment = Google::Protobuf::Any.pack(Google::Protobuf::Duration.new(seconds: 3))
    request = Echo::EchoRequest.new(text: "héllo", sent_at: sent_at, tags: {"a" => 2**40}, attachments: [attachment])
    reply = stub.say(request)
    assert_instance_of Echo::EchoReply, reply
    assert_equal "héllo", reply.text
    assert_equal sent_at, reply.sent_at
    assert_equal({"a" => 2**40}, reply.tags.to_h)
    assert_equal Google::Protobuf::Duration.new(seconds: 3), reply.attachments.first.unpack(Google::Protobuf::Duration)
  end

  def test_client_streaming
    requests = %w[a b c].map { |t| Echo::EchoRequest.new(text: t) }
    reply = stub.collect(requests.each)
    assert_equal "a,b,c", reply.text
    assert_equal 3, reply.index
  end

  def test_server_streaming
    replies = stub.repeat(Echo::EchoRequest.new(text: "x", times: 4)).to_a
    assert_equal [0, 1, 2, 3], replies.map(&:index)
    assert(replies.all? { |r| r.text == "x" })
  end

  def test_bidi_streaming
    requests = [Echo::EchoRequest.new(text: "one", times: 1), Echo::EchoRequest.new(text: "two", times: 2)]
    replies = stub.chat(requests.each).to_a
    assert_equal [["ONE", 1], ["TWO", 2]], replies.map { |r| [r.text, r.index] }
  end

  def test_well_known_types_as_request_and_response
    assert_equal Google::Protobuf::Empty.new, stub.ping(Google::Protobuf::Empty.new)
  end

  def test_rich_error_details
    error = assert_raises(GRPC::InvalidArgument) { stub.say(Echo::EchoRequest.new(text: "fail")) }
    status = error.to_rpc_status
    assert_instance_of Google::Rpc::Status, status
    assert_equal GRPC::Core::StatusCodes::INVALID_ARGUMENT, status.code
    detail = status.details.first
    assert detail.is(Echo::EchoReply)
    assert_equal Echo::EchoReply.new(text: "why", index: 7), detail.unpack(Echo::EchoReply)
  end

  def test_google_rpc_status_with_any
    any = Google::Protobuf::Any.pack(Echo::EchoRequest.new(text: "inside"))
    status = Google::Rpc::Status.new(code: 5, message: "not found", details: [any])
    decoded = Google::Rpc::Status.decode(Google::Rpc::Status.encode(status))
    assert_equal status, decoded
    assert_equal "type.googleapis.com/shimtest.echo.EchoRequest", decoded.details.first.type_url
    assert_equal "inside", decoded.details.first.unpack(Echo::EchoRequest).text
    json = Google::Rpc::Status.encode_json(status)
    assert_equal status, Google::Rpc::Status.decode_json(json)
  end
end
