# frozen_string_literal: true

require "test_helper"

# For every message of every corpus golden's own file: random instances
# survive encode and decode, re-encode to the same bytes, and survive to_h and new.
class PropertyTest < Minitest::Test
  INSTANCES = Integer(ENV.fetch("PROTOSTAR_PROPERTY_INSTANCES", "4"))

  CodecFixtures.goldens.each do |relative|
    define_method(:"test_round_trips_#{relative.tr("/.", "__")}") do
      set = CodecFixtures.load(relative)
      random = Random.new(relative.sum)
      checked = 0
      set.file.all_messages.each do |descriptor|
        next if descriptor.map_entry?
        klass = set[descriptor.full_name]
        INSTANCES.times do |n|
          message = RandomMessage.build(klass, random: random, depth: 3, fill: (n == 0) ? 1.0 : 0.5)
          assert_round_trip(message)
          checked += 1
        end
      end
      pass if checked.zero?
    end
  end

  private

  def assert_round_trip(message)
    klass = message.class
    bytes = message.encode
    assert_equal bytes.bytesize, message.__size({}.compare_by_identity), "sizer and writer disagree"
    decoded = klass.decode(bytes)
    assert_equal message, decoded, "decode(encode(m)) differs for #{klass.descriptor.full_name}"
    assert_equal message.unknown_fields, decoded.unknown_fields
    assert_equal bytes, decoded.encode, "re-encoding differs for #{klass.descriptor.full_name}"
    assert_equal message, klass.new(message.__to_h), "to_h does not round trip for #{klass.descriptor.full_name}"
    frozen = klass.decode(bytes, frozen: true)
    assert_equal message, frozen
    assert Ractor.shareable?(frozen)
  end
end
