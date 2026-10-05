# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# conformance/run_testee driven through its stdin protocol, as the runner does,
# with message classes from the corpus goldens rather than the testee's own
class ConformanceTesteeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  TESTEE = File.join(ROOT, "conformance", "run_testee")
  PROTO3 = "protobuf_test_messages.proto3.TestAllTypesProto3"
  PROTO2 = "protobuf_test_messages.proto2.TestAllTypesProto2"

  def setup
    @protocol = CodecFixtures.load("conformance/conformance.proto")
    @set3 = CodecFixtures.load("google/protobuf/test_messages_proto3.proto")
    @set2 = CodecFixtures.load("google/protobuf/test_messages_proto2.proto")
  end

  def request(**fields)
    @protocol["conformance.ConformanceRequest"].new(**fields)
  end

  # Sends every request to one testee process; returns the responses and its stderr
  def exchange(*requests)
    input = requests.map { |r|
      bytes = r.encode
      [bytes.bytesize].pack("V") + bytes
    }.join
    out, err, status = Open3.capture3(RbConfig.ruby, TESTEE, stdin_data: input, binmode: true)
    assert status.success?, "testee exited with #{status.exitstatus}: #{err}"
    responses = []
    until out.empty?
      length = out.byteslice(0, 4).unpack1("V")
      responses << @protocol["conformance.ConformanceResponse"].decode(out.byteslice(4, length))
      out = out.byteslice(4 + length..)
    end
    assert_equal requests.size, responses.size, "one response per request"
    [responses, err]
  end

  def test_every_payload_kind_and_output_format
    proto3 = @set3[PROTO3]
    message = proto3.new(optional_int32: -5, optional_string: "héllo", repeated_nested_enum: [:BAZ, :NEG],
      map_string_string: {"k" => "v"}, optional_any: @set3["google.protobuf.Any"].new(
        type_url: "type.googleapis.com/#{PROTO3}", value: proto3.new(optional_bool: true).encode
      ))
    json = %({"optionalInt32":-5,"optionalString":"héllo","repeatedNestedEnum":["BAZ","NEG"],) +
      %("mapStringString":{"k":"v"},"optionalAny":{"@type":"type.googleapis.com/#{PROTO3}","optionalBool":true}})
    text = Protostar::Text.print(message, registry: @set3.registry)
    payloads = {protobuf_payload: message.encode, json_payload: json, text_payload: text}
    formats = %i[PROTOBUF JSON TEXT_FORMAT]
    requests = payloads.flat_map do |kind, payload|
      formats.map { |format| request(kind => payload, :requested_output_format => format, :message_type => PROTO3) }
    end
    responses, err = exchange(*requests)
    responses.each_with_index do |response, i|
      kind = payloads.keys[i / 3]
      case formats[i % 3]
      when :PROTOBUF
        assert_equal message, proto3.decode(response.protobuf_payload), "#{kind} to binary"
      when :JSON
        assert_equal json, response.json_payload, "#{kind} to JSON"
      when :TEXT_FORMAT
        assert_equal text, response.text_payload, "#{kind} to text"
      end
    end
    assert_match(/input ended after 9 requests/, err)
  end

  def test_proto2_and_editions_types_resolve
    two = @set2[PROTO2].new(optional_int32: 1, optional_nested_enum: :BAR)
    editions = "protobuf_test_messages.editions.TestAllTypesEdition2023"
    responses, = exchange(
      request(protobuf_payload: two.encode, requested_output_format: :JSON, message_type: PROTO2),
      request(protobuf_payload: "\x08\x07".b, requested_output_format: :TEXT_FORMAT, message_type: editions)
    )
    assert_equal %({"optionalInt32":1,"optionalNestedEnum":"BAR"}), responses[0].json_payload
    assert_equal "optional_int32: 7\n", responses[1].text_payload
  end

  def test_ignore_unknown_fields_follows_the_test_category
    json = %({"optionalInt32":3,"noSuchField":1})
    responses, = exchange(
      request(json_payload: json, requested_output_format: :JSON, message_type: PROTO3, test_category: :JSON_TEST),
      request(json_payload: json, requested_output_format: :JSON, message_type: PROTO3,
        test_category: :JSON_IGNORE_UNKNOWN_PARSING_TEST)
    )
    assert_equal :parse_error, responses[0].which_result
    assert_equal %({"optionalInt32":3}), responses[1].json_payload
  end

  def test_unknown_fields_print_only_when_asked
    bytes = "\x08\x01\xb8\x3e\x02".b # optional_int32 1, then unknown field 999
    responses, = exchange(
      request(protobuf_payload: bytes, requested_output_format: :TEXT_FORMAT, message_type: PROTO3),
      request(protobuf_payload: bytes, requested_output_format: :TEXT_FORMAT, message_type: PROTO3,
        print_unknown_fields: true),
      request(protobuf_payload: bytes, requested_output_format: :PROTOBUF, message_type: PROTO3)
    )
    assert_equal "optional_int32: 1\n", responses[0].text_payload
    assert_equal "optional_int32: 1\n999: 2\n", responses[1].text_payload
    assert_equal bytes, responses[2].protobuf_payload
  end

  def test_errors_are_answered_not_raised
    responses, err = exchange(
      request(protobuf_payload: "\x08".b, requested_output_format: :PROTOBUF, message_type: PROTO3),
      request(json_payload: "{", requested_output_format: :PROTOBUF, message_type: PROTO3),
      request(text_payload: "optional_int32: x", requested_output_format: :PROTOBUF, message_type: PROTO3),
      request(protobuf_payload: "", requested_output_format: :PROTOBUF, message_type: "no.Such"),
      request(jspb_payload: "[]", requested_output_format: :PROTOBUF, message_type: PROTO3),
      request(protobuf_payload: "", requested_output_format: :JSPB, message_type: PROTO3),
      request(protobuf_payload: "", requested_output_format: :UNSPECIFIED, message_type: PROTO3),
      request(requested_output_format: :PROTOBUF, message_type: PROTO3),
      # a Timestamp beyond year 9999 has no JSON form
      request(protobuf_payload: "\xf2\x12\x07\x08\x80\x80\x80\x80\x80\x08".b, requested_output_format: :JSON,
        message_type: PROTO3)
    )
    assert_equal %i[parse_error parse_error parse_error runtime_error skipped skipped runtime_error runtime_error
      serialize_error], responses.map(&:which_result)
    assert_match(/DecodeError/, responses[0].parse_error)
    assert_equal "No such message type: no.Such", responses[3].runtime_error
    assert_match(/input ended after 9 requests/, err)
  end

  def test_empty_input_is_a_clean_exit
    responses, err = exchange
    assert_empty responses
    assert_match(/input ended after 0 requests/, err)
  end

  def test_a_truncated_request_fails_the_process
    _, _, status = Open3.capture3(RbConfig.ruby, TESTEE, stdin_data: [10].pack("V") + "abc", binmode: true)
    refute status.success?
  end
end
