# frozen_string_literal: true

require "test_helper"

# Cross-checks against google-protobuf, in both directions: bytes we encode
# decode in the oracle to the same to_h, and bytes the oracle encodes decode
# in ours to the same to_h. Runs only with PROTOSTAR_ORACLE=1 and the oracle bundle.
class OracleTest < Minitest::Test
  # The files the WS3 spec names; every other golden is checked as well
  NAMED = %w[
    google/protobuf/unittest.proto
    google/protobuf/unittest_proto3.proto
    google/protobuf/map_unittest.proto
    google/protobuf/unittest_proto3_optional.proto
    google/protobuf/unittest_delimited.proto
    google/protobuf/edition_unittest.proto
    google/protobuf/unittest_mset.proto
    google/protobuf/unittest_preserve_unknown_enum.proto
  ].freeze

  INSTANCES = Integer(ENV.fetch("PROTOSTAR_ORACLE_INSTANCES", "6"))

  def setup
    skip "set PROTOSTAR_ORACLE=1 with BUNDLE_WITH=oracle to cross-check against google-protobuf" unless Oracle.available?
  end

  def test_named_files_are_goldens
    NAMED.each { |relative| assert_includes CodecFixtures.goldens, relative }
  end

  CodecFixtures.goldens.each do |relative|
    define_method(:"test_oracle_#{relative.tr("/.", "__")}") do
      set = CodecFixtures.load(relative)
      pool = Oracle.pool(relative)
      random = Random.new(relative.sum + 1)
      set.file.all_messages.each do |descriptor|
        next if descriptor.map_entry?
        klass = set[descriptor.full_name]
        oracle = pool.lookup(descriptor.full_name).msgclass
        INSTANCES.times do |n|
          message = RandomMessage.build(klass, random: random, depth: 3, fill: (n == 0) ? 1.0 : 0.5)
          check(message, oracle)
        end
      end
    end
  end

  # Values only a hand-written message reaches reliably
  def test_edge_values_unittest
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    oracle = Oracle.pool("google/protobuf/unittest.proto").lookup("proto2_unittest.TestAllTypes").msgclass
    message = set["proto2_unittest.TestAllTypes"].new(
      optional_int32: -1, optional_int64: -2**63, optional_uint64: 2**64 - 1, optional_sint32: -2**31,
      optional_sint64: 2**63 - 1, optional_float: -0.0, optional_double: Float::NAN,
      repeated_float: [Float::INFINITY, -Float::INFINITY, 1.401298464324817e-45],
      repeated_double: [5e-324, -0.0], optional_string: "日本語 😀", optional_bytes: "\x00\xff".b,
      optional_nested_enum: :NEG, repeated_nested_enum: %i[FOO NEG]
    )
    check(message, oracle)
  end

  private

  def check(message, oracle)
    name = message.class.descriptor.full_name
    bytes = message.encode
    theirs = oracle.decode(bytes)
    expected = normalize(message.__to_h)
    assert_equal expected, normalize(theirs.to_h), "the oracle reads our #{name} differently"
    ours = message.class.decode(oracle.encode(theirs))
    assert_equal expected, normalize(ours.__to_h), "we read the oracle's #{name} differently"
    assert_equal message, ours
  end

  # NaN never equals itself in a Hash comparison; strings compare by bytes
  def normalize(value)
    case value
    when Hash then value.to_h { |k, v| [normalize(k), normalize(v)] }
    when Array then value.map { |v| normalize(v) }
    when Float then value.nan? ? :NaN : value
    when String then value.b
    else value
    end
  end
end
