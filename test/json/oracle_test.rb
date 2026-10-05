# frozen_string_literal: true

require "test_helper"

# Cross-checks JSON against google-protobuf: for random messages our
# encode_json equals the oracle's under every option combination, the
# oracle's JSON parses in ours to an equal message, and ours parses in the
# oracle's to an equal message. Runs only with PROTOSTAR_ORACLE=1 and the
# oracle bundle.
class JSONOracleTest < Minitest::Test
  FILES = %w[
    google/protobuf/unittest_proto3.proto
    google/protobuf/test_messages_proto3.proto
    google/protobuf/map_unittest.proto
    google/protobuf/unittest_proto3_optional.proto
    google/protobuf/duration.proto
    google/protobuf/timestamp.proto
    google/protobuf/struct.proto
    google/protobuf/wrappers.proto
    google/protobuf/field_mask.proto
    google/protobuf/empty.proto
  ].freeze

  WRAPPERS = %w[Double Float Int64 UInt64 Int32 UInt32 Bool String Bytes].map { |w| "google.protobuf.#{w}Value" }.freeze

  INSTANCES = Integer(ENV.fetch("PROTOSTAR_ORACLE_INSTANCES", "6"))

  OPTIONS = [false, true].product([false, true], [false, true]).map do |names, defaults, ints|
    {preserve_proto_field_names: names, emit_defaults: defaults, format_enums_as_integers: ints}
  end.freeze

  def setup
    skip "set PROTOSTAR_ORACLE=1 with BUNDLE_WITH=oracle to cross-check against google-protobuf" unless Oracle.available?
  end

  FILES.each do |relative|
    define_method(:"test_oracle_json_#{relative.tr("/.", "__")}") do
      set = CodecFixtures.load(relative)
      pool = Oracle.pool(relative)
      random = Random.new(relative.sum + 5)
      checked = 0
      set.file.all_messages.each do |descriptor|
        next if descriptor.map_entry?
        klass = set[descriptor.full_name]
        oracle = pool.lookup(descriptor.full_name).msgclass
        INSTANCES.times do |n|
          message = RandomMessage.build(klass, random: random, depth: 3, fill: (n == 0) ? 1.0 : 0.5)
          WellKnownRandom.sanitize(message, random: random, registry: set.registry)
          check(set, message, oracle)
          checked += 1
        end
      end
      assert_operator checked, :>, 0
    end
  end

  private

  def check(set, message, oracle)
    name = message.class.descriptor.full_name
    theirs = oracle.decode(message.encode)
    OPTIONS.each do |options|
      gem_options = options.merge(preserve_proto_fieldnames: options[:preserve_proto_field_names])
      gem_options.delete(:preserve_proto_field_names)
      expected = oracle.encode_json(theirs, gem_options)
      actual = message.class.encode_json(message, **options, registry: set.registry)
      assert_same_json expected, actual, "#{name} with #{options}"
      parsed = message.class.decode_json(expected, registry: set.registry)
      assert_equal message, parsed, "we read the oracle's JSON for #{name} differently: #{expected}"
      # google-protobuf refuses to parse a wrapper at the top level
      next if WRAPPERS.include?(name)
      back = message.class.decode(oracle.encode(oracle.decode_json(actual)))
      assert_equal message, back, "the oracle reads our JSON for #{name} differently: #{actual}"
    end
  end

  # Exact text, except that map entries may come in another order: then the
  # parsed trees must be equal and every number spelled the same way
  def assert_same_json(expected, actual, message)
    return pass if expected == actual
    assert_equal ::JSON.parse(expected), ::JSON.parse(actual), message
    tokens = ->(s) { s.scan(/"(?:[^"\\]|\\.)*"|-?\d[\d.eE+-]*/).sort }
    assert_equal tokens.call(expected), tokens.call(actual), "#{message}: same tree, different spelling"
  end
end
