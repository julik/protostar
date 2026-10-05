# frozen_string_literal: true

require "test_helper"

# Every corpus golden reads through Schema::File.from_proto, links, freezes,
# and translates back to exactly what protoc wrote: the same bytes, and the
# same descriptors as the golden JSON
class GoldenRoundTripTest < Minitest::Test
  Dir[File.join(Corpus::GOLDENS, "**", "*.json")].sort.each do |path|
    relative = path.delete_prefix(Corpus::GOLDENS + "/").delete_suffix(".json")
    define_method(:"test_round_trips_#{relative.gsub(/\W+/, "_")}") do
      pool = Protostar::Schema::Pool.new
      types = Protostar::Schema::Proto.types
      protos = types::FileDescriptorSet.decode(File.binread(path.sub(/\.json\z/, ".binpb"))).file
      protos.zip(GoldenHash.load(path)) do |proto, expected|
        file = Protostar::Schema::File.from_proto(proto, pool: pool)
        assert_equal proto.encode, file.serialize, "#{proto.name} does not round-trip"
        assert_equal expected, file.to_proto(source_info: false).to_h, "#{proto.name} differs from the golden"
        assert Ractor.shareable?(file), "#{proto.name} is not shareable"
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
