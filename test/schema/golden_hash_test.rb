# frozen_string_literal: true

require "test_helper"

class GoldenHashTest < Minitest::Test
  def test_converts_json_names_enums_and_integers
    unittest = GoldenHash.load(Corpus.golden("google/protobuf/unittest.proto", :json)).last
    assert_equal "google/protobuf/unittest.proto", unittest[:name]
    assert_equal :EDITION_2023, unittest[:edition]
    assert_equal({enum_type: :CLOSED, repeated_field_encoding: :EXPANDED, utf8_validation: :NONE},
      unittest[:options][:features])
    assert_equal :SPEED, unittest[:options][:optimize_for]

    all_types = unittest[:message_type].find { |m| m[:name] == "TestAllTypes" }
    field = all_types[:field].first
    assert_equal({name: "optional_int32", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32,
                  json_name: "optionalInt32"}, field)
  end

  def test_names_editions_the_json_printer_wrote_as_numbers
    delimited = GoldenHash.load(Corpus.golden("google/protobuf/unittest_delimited.proto", :json)).last
    assert_equal :EDITION_2026, delimited[:edition]
  end

  def test_rejects_keys_descriptor_proto_does_not_have
    assert_raises(ArgumentError) { GoldenHash.convert({"bogus" => 1}, "google.protobuf.FileDescriptorProto") }
  end

  def test_matches_google_protobuf_to_h_for_every_golden
    skip "needs PROTOSTAR_ORACLE=1 and the google-protobuf gem" unless Oracle.available?
    Dir[File.join(Corpus::GOLDENS, "**", "*.json")].sort.each do |json|
      binpb = json.sub(/\.json\z/, ".binpb")
      assert_equal Oracle.file_hashes(binpb), GoldenHash.load(json), json
    end
  end

  private
end
