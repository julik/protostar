# frozen_string_literal: true

require "test_helper"
require "json"

# The protoc-made fixtures under test/corpus/text_format (see
# script/make_text_fixtures.rb): parsing the source text gives protoc's
# bytes, printing those bytes gives protoc's text, and printing them as a
# message with no fields gives protoc's rendering of unknown fields.
class TextFixturesTest < Minitest::Test
  DIR = File.join(Corpus::ROOT, "text_format")
  MANIFEST = JSON.parse(File.read(File.join(DIR, "manifest.json")))
  SOURCES = [File.join(Corpus::PROTOBUF, "src", "google", "protobuf", "testdata"), File.expand_path("inputs", __dir__)].freeze

  def test_every_corpus_text_format_file_is_a_fixture
    corpus = Dir[File.join(SOURCES.first, "text_format_*.txt")].map { |p| File.basename(p, ".txt") }
    assert_equal 6, corpus.size
    corpus.each { |name| assert MANIFEST.key?(name), "#{name} is missing from the fixtures" }
  end

  MANIFEST.each do |name, meta|
    error = File.join(DIR, "#{name}.error.txt")
    if File.exist?(error)
      define_method(:"test_rejects_#{name}") do
        klass = CodecFixtures.load(meta["proto"])[meta["message"]]
        e = assert_raises(Protostar::Text::ParseError) { Protostar::Text.parse(klass, source(name)) }
        # protoc and we both refuse a second member of a oneof
        assert_match(/another member of oneof "oneof_field"/, File.read(error))
        assert_match(/another member of oneof "oneof_field"/, e.message)
      end
      next
    end

    define_method(:"test_parse_#{name}") do
      set = CodecFixtures.load(meta["proto"])
      parsed = Protostar::Text.parse(set[meta["message"]], source(name), registry: set.registry)
      assert_equal File.binread(File.join(DIR, "#{name}.binpb")), parsed.encode
    end

    define_method(:"test_print_#{name}") do
      set = CodecFixtures.load(meta["proto"])
      message = set[meta["message"]].decode(File.binread(File.join(DIR, "#{name}.binpb")))
      assert_equal File.read(File.join(DIR, "#{name}.txt")), Protostar::Text.print(message, expand_any: false, registry: set.registry)
    end

    define_method(:"test_print_unknown_#{name}") do
      empty = CodecFixtures.load("google/protobuf/unittest.proto")["proto2_unittest.TestEmptyMessage"]
      message = empty.decode(File.binread(File.join(DIR, "#{name}.binpb")))
      assert_equal File.read(File.join(DIR, "#{name}.unknown.txt")), Protostar::Text.print(message)
    end

    define_method(:"test_reparse_#{name}") do
      set = CodecFixtures.load(meta["proto"])
      text = File.read(File.join(DIR, "#{name}.txt"))
      # protoc's printing sorts map entries and drops the sign of NaN, so
      # the bytes may differ while the messages are equal
      decoded = set[meta["message"]].decode(File.binread(File.join(DIR, "#{name}.binpb")))
      parsed = Protostar::Text.parse(set[meta["message"]], text, registry: set.registry)
      assert_equal decoded, parsed
      assert_equal decoded.unknown_fields, parsed.unknown_fields
    end
  end

  private

  def source(name)
    File.read(SOURCES.map { |dir| File.join(dir, "#{name}.txt") }.find { |p| File.exist?(p) })
  end
end
