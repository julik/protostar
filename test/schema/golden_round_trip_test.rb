# frozen_string_literal: true

require "test_helper"

# Every corpus golden builds, links, freezes and reproduces protoc's own hash
class GoldenRoundTripTest < Minitest::Test
  Dir[File.join(Corpus::GOLDENS, "**", "*.json")].sort.each do |path|
    relative = path.delete_prefix(Corpus::GOLDENS + "/").delete_suffix(".json")
    define_method(:"test_round_trips_#{relative.gsub(/\W+/, "_")}") do
      pool = Protostar::Schema::Pool.new
      GoldenHash.load(path).each do |hash|
        file = Protostar::Schema::Builder.build(hash, pool: pool)
        assert_equal hash, file.to_h, "#{hash[:name]} does not round-trip"
        assert Ractor.shareable?(file), "#{hash[:name]} is not shareable"
        refute hash.frozen?, "building froze the caller's hash"
        pool.add(file)
      end
    end
  end

  def test_the_corpus_has_goldens_in_every_syntax
    syntaxes = Dir[File.join(Corpus::GOLDENS, "**", "*.json")].flat_map do |path|
      GoldenHash.load(path).map { |h| h[:syntax] }
    end.uniq
    assert_equal [nil, "editions", "proto3"].sort_by(&:to_s), syntaxes.sort_by(&:to_s)
  end
end
