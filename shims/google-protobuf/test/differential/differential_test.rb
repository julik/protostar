# frozen_string_literal: true

require "test/unit"
require_relative "probe"

# Every probe in probes.txt gives what google-protobuf 4.36.2 gave when it was
# recorded (script/record_differential.rb), except those marked as known
# differences. Probes share state, so they all run once, in order, up front.
class DifferentialTest < Test::Unit::TestCase
  PROBES = Differential.probes
  RECORDED = Differential.recorded
  binding = Differential.setup
  RESULTS = PROBES.map { |probe| Differential.run(probe.source, binding) }

  def test_every_probe_was_recorded
    assert_equal PROBES.size, RECORDED.size, "re-record with script/record_differential.rb"
  end

  PROBES.each_with_index do |probe, i|
    define_method(format("test_probe_%03d", i)) do
      omit(probe.difference) if probe.difference
      assert_equal RECORDED.fetch(i), RESULTS.fetch(i), probe.source
    end
  end
end
