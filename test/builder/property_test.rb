# frozen_string_literal: true

require_relative "builder_support"

# For random messages of every corpus golden's own file: a builder block replayed from the message's field
# hash, with a nested block for every message and a collection block for
# every repeated message, produces bytes that decode to an equal message;
# so does merge! of the same hash, and the block with every nested message
# chunked at every field.
class BuilderPropertyTest < Minitest::Test
  INSTANCES = Integer(ENV.fetch("PROTOSTAR_PROPERTY_INSTANCES", "4"))

  CodecFixtures.goldens.each do |relative|
    define_method(:"test_builder_round_trips_#{relative.tr("/.", "__")}") do
      set = CodecFixtures.load(relative)
      random = Random.new(relative.sum + 9)
      checked = 0
      set.file.all_messages.each do |descriptor|
        next if descriptor.map_entry?
        klass = set[descriptor.full_name]
        INSTANCES.times do |n|
          message = RandomMessage.build(klass, random: random, depth: 3, fill: (n == 0) ? 1.0 : 0.5, unknown: false)
          assert_builds(message)
          checked += 1
        end
      end
      pass if checked.zero?
    end
  end

  private

  def assert_builds(message)
    klass = message.class
    hash = message.__to_h
    name = klass.descriptor.full_name
    replayed = Protostar::Builder.build(klass) { |pb| BuilderSupport.replay(pb, klass, hash) }
    assert_equal message, klass.decode(replayed), "replayed block for #{name}: #{hash.inspect[0, 300]}"
    merged = Protostar::Builder.build(klass) { |pb| pb.merge!(hash) }
    assert_equal message, klass.decode(merged), "merge! for #{name}"
    assert_equal replayed, merged
    # every nested message split at every field: readers merge the pieces back
    chunked = Protostar::Builder.build(klass, chunk_nested_at: 1) { |pb| BuilderSupport.replay(pb, klass, hash) }
    assert_equal message, klass.decode(chunked), "chunk_nested_at: 1 for #{name}"
  end
end
