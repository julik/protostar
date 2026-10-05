# frozen_string_literal: true

require "test_helper"

# Every corpus file goes through the native emitter, is loaded in a fresh
# process with a fresh generated pool, and must build to exactly the
# descriptors the compiler made (custom options included) and to the golden
# hash; every message and enum must sit under protoc's Ruby constant name.
# Emitting again from the loaded descriptors gives the same text.
class RubyCorpusTest < Minitest::Test
  Emitters = Protostar::Compiler::Emitters

  CompilerSupport.goldens.each do |rel|
    define_method(:"test_#{rel.tr("/.", "__")}") do
      compiled = EmitterSupport.compiled(rel)
      answer = EmitterSupport.loaded(rel)
      assert_empty answer[:errors]
      assert_empty answer[:warnings]
      golden = GoldenHash.load(Corpus.golden(rel, :json))
      compiled.bare.zip(golden) do |file, expected|
        loaded = answer[:files].fetch(file.name)
        refute loaded[:missing], "#{file.name} was not loaded"
        assert_equal EmitterSupport.comparable(file.to_h), EmitterSupport.comparable(loaded[:to_h]),
          "#{file.name} differs from the compiled descriptors"
        assert_equal EmitterSupport.comparable(expected),
          EmitterSupport.comparable(CompilerSupport.strip_extensions(loaded[:to_h])), "#{file.name} differs from the golden"
        assert_empty loaded[:wrong_constants], "#{file.name} constants"
        assert loaded[:shareable]
        next if Emitters::BOOTSTRAP.include?(file.name)
        assert_equal EmitterSupport.emitter.file(file), loaded[:source], "#{file.name} emits differently once loaded"
      end
    end
  end
end
