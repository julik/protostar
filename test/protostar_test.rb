# frozen_string_literal: true

require "test_helper"

class ProtostarTest < Minitest::Test
  def test_has_a_version
    assert_match(/\A\d+\.\d+\.\d+/, Protostar::VERSION)
  end

  def test_corpus_goldens_are_present
    binpbs = Dir[File.join(Corpus::GOLDENS, "**", "*.binpb")]
    assert_operator binpbs.size, :>, 80, "expected the committed protoc goldens"
  end
end
