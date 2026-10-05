# frozen_string_literal: true

require "test_helper"

# Printing a random message and parsing the text back gives the same
# message, for every message of every golden's own file, in both layouts
class TextRoundTripTest < Minitest::Test
  INSTANCES = 3

  CodecFixtures.goldens.each do |relative|
    define_method(:"test_round_trip_#{relative.tr("/.", "__")}") do
      set = CodecFixtures.load(relative)
      random = Random.new(relative.sum + 11)
      set.file.all_messages.each do |descriptor|
        next if descriptor.map_entry?
        klass = set[descriptor.full_name]
        INSTANCES.times do |n|
          message = RandomMessage.build(klass, random: random, depth: 3, fill: (n == 0) ? 1.0 : 0.5, unknown: false)
          [false, true].each do |single_line|
            text = Protostar::Text.print(message, single_line: single_line, registry: set.registry)
            refute_includes text, "\n", "single_line printed several lines" if single_line
            parsed = Protostar::Text.parse(klass, text, registry: set.registry)
            assert_equal message, parsed, "#{descriptor.full_name} does not round-trip through:\n#{text}"
          end
        end
      end
    end
  end
end
