# frozen_string_literal: true

require "test_helper"

# Tier B without the oracle: every .binpb golden decodes through
# Protostar.load_descriptor_set, with our own codec and bootstrap, into files
# whose descriptors equal the compiler's (source info and custom options
# included) and the golden JSON, and which serialize back to the same bytes.
class LoadDescriptorSetTest < Minitest::Test
  CompilerSupport.goldens.each do |rel|
    define_method(:"test_#{rel.tr("/.", "__")}") do
      bytes = File.binread(Corpus.golden(rel, :binpb))
      pool = Protostar::Schema::Pool.new
      files = Protostar.load_descriptor_set(bytes, pool: pool)
      compiled = EmitterSupport.compiled(rel).files
      assert_equal compiled.map(&:name), files.map(&:name)
      golden = GoldenHash.load(Corpus.golden(rel, :json))
      files.zip(compiled, golden) do |file, ours, expected|
        assert_same file, pool.file(file.name)
        assert Ractor.shareable?(file)
        assert_equal ours.serialize, file.serialize, file.name
        bare = file.to_proto(source_info: false).to_h
        assert_equal EmitterSupport.comparable(expected), EmitterSupport.comparable(bare), file.name
      end
      emitter = Protostar::Compiler::Emitters::DescriptorSet.new(include_source_info: true, pool: pool)
      assert_equal bytes, emitter.emit(files)
    end
  end
end
