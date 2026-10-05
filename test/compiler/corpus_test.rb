# frozen_string_literal: true

require "test_helper"

# Tier A: every corpus file compiles to exactly the descriptors protoc 36.2
# wrote for it with --include_imports, in the same order, with the same
# diagnostics. Each file is translated to protoc's shape (`to_proto`) and
# compared with the golden JSON read by protostar's JSON parser. The goldens
# cannot hold custom option values (protoc's JSON drops extensions it cannot
# name, as `to_proto.to_h` drops the unknown fields that hold them), so those
# are compared in custom_options_test.rb and descriptor_set_test.rb instead.
class CompilerCorpusTest < Minitest::Test
  CompilerSupport.goldens.each do |rel|
    define_method(:"test_#{rel.tr("/.", "__")}") do
      compiler = CompilerSupport.compiler
      files = compiler.compile([rel])
      expected = GoldenHash.load(Corpus.golden(rel, :json))

      assert_equal expected.map { |h| h[:name] }, files.map(&:name)
      expected.zip(files) do |hash, file|
        assert_equal hash, file.to_proto.to_h, "#{file.name} differs from the golden"
        assert Ractor.shareable?(file)
      end
      assert_equal CompilerSupport::CORPUS_WARNINGS.fetch(rel, []), compiler.diagnostics.map(&:to_s)
    end
  end

  def test_every_corpus_proto_has_a_golden
    assert_equal Corpus.protos.size, CompilerSupport.goldens.size
  end
end
