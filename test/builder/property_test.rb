# frozen_string_literal: true

require_relative "builder_support"

# For random messages of every corpus golden's own file: a builder block replayed from the message's field
# hash, with a nested block for every message and a collection block for
# every repeated message, produces bytes that decode to an equal message;
# so does merge! of the same hash.
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
    replayed = Protostar::Builder.build(klass) { |pb| replay(pb, klass, hash) }
    assert_equal message, klass.decode(replayed), "replayed block for #{name}: #{hash.inspect[0, 300]}"
    merged = Protostar::Builder.build(klass) { |pb| pb.merge!(hash) }
    assert_equal message, klass.decode(merged), "merge! for #{name}"
    assert_equal replayed, merged
  end

  # Writes a field hash as a template would: field methods where the builder
  # has them, set! where it does not, blocks for nested and repeated messages
  def replay(pb, klass, hash)
    hash.each do |name, value|
      info = klass.__by_name.fetch(name)
      if info.message? && !info.map && info.repeated
        call(pb, name, value) { |h| replay(pb, info.message_class, h) }
      elsif info.message? && !info.map
        call(pb, name) { replay(pb, info.message_class, value) }
      else
        call(pb, name, value)
      end
    end
  end

  def call(pb, name, *args, &block)
    if pb.class.public_method_defined?(name, false)
      pb.public_send(name, *args, &block)
    else
      pb.set!(name, *args, &block)
    end
  end
end
