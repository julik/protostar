# frozen_string_literal: true

require "test_helper"

class SourceInfoTest < Minitest::Test
  S = Protostar::Schema

  SOURCE = {
    location: [
      {span: [0, 0, 12, 1]},
      {path: [4, 0], span: [3, 0, 6, 1], leading_comments: " A message.\n",
       leading_detached_comments: [" Detached.\n", " Another.\n"]},
      {path: [4, 0, 2, 0], span: [5, 2, 17], trailing_comments: " the id\n"},
      {path: [4, 0], span: [3, 0, 7]}
    ]
  }.freeze

  def build
    S::Builder.build({name: "src.proto", message_type: [{name: "M"}], source_code_info: SOURCE}, pool: S::Pool.new)
  end

  def test_keeps_locations_verbatim
    info = build.source_info
    assert_equal 4, info.locations.size
    root, message, field, = info.locations
    assert_equal [], root.path
    assert_equal [0, 0, 12, 1], root.span
    assert_nil root.leading_comments
    assert_equal " A message.\n", message.leading_comments
    assert_equal [" Detached.\n", " Another.\n"], message.leading_detached_comments
    assert_equal " the id\n", field.trailing_comments
    assert_equal [], field.leading_detached_comments
  end

  def test_location_by_path_returns_the_first_one
    info = build.source_info
    assert_equal [3, 0, 6, 1], info.location([4, 0]).span
    assert_equal [5, 2, 17], info.location([4, 0, 2, 0]).span
    assert_nil info.location([9])
  end

  def test_round_trips_through_to_h
    file = build
    assert_equal SOURCE, file.to_h[:source_code_info]
    assert Ractor.shareable?(file.source_info)
  end

  def test_absent_without_source_code_info
    file = S::Builder.build({name: "bare.proto"}, pool: S::Pool.new)
    assert_nil file.source_info
    refute file.to_h.key?(:source_code_info)
  end

  def test_round_trips_protoc_source_info_from_every_binpb
    skip "needs PROTOSTAR_ORACLE=1 and the google-protobuf gem to read .binpb" unless Oracle.available?
    Dir[File.join(Corpus::GOLDENS, "**", "*.binpb")].sort.each do |binpb|
      pool = S::Pool.new
      Oracle.file_hashes(binpb, source_info: true).each do |hash|
        file = S::Builder.build(hash, pool: pool)
        assert_equal hash, file.to_h, "#{binpb}: #{hash[:name]}"
        refute_nil file.source_info
        pool.add(file)
      end
    end
  end
end
