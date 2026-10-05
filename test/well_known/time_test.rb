# frozen_string_literal: true

require "test_helper"
require "date"

class WellKnownTimeTest < Minitest::Test
  def setup
    @timestamp = CodecFixtures.load("google/protobuf/timestamp.proto")["google.protobuf.Timestamp"]
    @duration = CodecFixtures.load("google/protobuf/duration.proto")["google.protobuf.Duration"]
  end

  def test_from_time_keeps_nanoseconds
    time = Time.at(1_700_000_000, 123_456_789, :nanosecond)
    ts = @timestamp.from_time(time)
    assert_equal [1_700_000_000, 123_456_789], [ts.seconds, ts.nanos]
    assert_equal time, ts.to_time
    assert_equal 123_456_789, ts.to_time.nsec
    same = @timestamp.new
    assert_same same, same.from_time(time)
    assert_equal ts, same
  end

  def test_times_in_other_zones_mean_the_same_instant
    utc = Time.utc(2024, 2, 29, 12, 0, 0)
    tokyo = Time.new(2024, 2, 29, 21, 0, 0, "+09:00")
    assert_equal @timestamp.from_time(utc), @timestamp.from_time(tokyo)
    assert_equal utc, @timestamp.from_time(tokyo).to_time
    assert_equal '"2024-02-29T12:00:00Z"', @timestamp.from_time(tokyo).to_json
  end

  def test_times_before_the_epoch
    time = Time.at(-1, 250_000_000, :nanosecond)
    ts = @timestamp.from_time(time)
    assert_equal [-1, 250_000_000], [ts.seconds, ts.nanos], "nanos stay positive, seconds go down"
    assert_equal time, ts.to_time
    assert_equal '"1969-12-31T23:59:59.250Z"', ts.to_json
  end

  def test_numeric_conversions
    ts = @timestamp.new(seconds: 10, nanos: 500_000_000)
    assert_equal 10, ts.to_i
    assert_equal Rational(21, 2), ts.to_f, "a Rational, as google-protobuf returns"
    assert_equal 10.5, Float(ts.to_f)
    assert_equal 1.5, @duration.new(seconds: 1, nanos: 500_000_000).to_f
    assert_equal(-1.5, @duration.new(seconds: -1, nanos: -500_000_000).to_f)
    assert_instance_of Float, @duration.new.to_f
  end

  def test_a_time_assigned_to_a_timestamp_field_becomes_a_timestamp
    klass = all_types
    @timestamp = proto3["google.protobuf.Timestamp"]
    time = Time.at(1_700_000_000, 123_456_789, :nanosecond)
    expected = @timestamp.new(seconds: 1_700_000_000, nanos: 123_456_789)
    assert_equal expected, klass.new(optional_timestamp: time).optional_timestamp
    m = klass.new
    m.optional_timestamp = time
    assert_equal expected, m.optional_timestamp
    m[:optional_timestamp] = Time.at(-0.5r)
    assert_equal @timestamp.new(seconds: -1, nanos: 500_000_000), m.optional_timestamp
    m.repeated_timestamp = [time, {seconds: 3}]
    assert_equal [expected, @timestamp.new(seconds: 3)], m.repeated_timestamp
    datetime = DateTime.new(2001, 2, 3, 4, 5, 6.5r)
    assert_equal Time.utc(2001, 2, 3, 4, 5, 6.5r), klass.new(optional_timestamp: datetime).optional_timestamp.to_time.utc
    error = assert_raises(Protostar::TypeError) { m.optional_timestamp = "2001-02-03" }
    assert_match(/optional_timestamp expects a google.protobuf.Timestamp or a Hash/, error.message)
  end

  def test_a_numeric_assigned_to_a_duration_field_becomes_a_duration
    @duration = proto3["google.protobuf.Duration"]
    {
      90 => [90, 0], 1.5 => [1, 500_000_000], -1.5 => [-1, -500_000_000], Rational(1, 3) => [0, 333_333_333],
      -0.25 => [0, -250_000_000], 0.9999999999 => [1, 0]
    }.each do |value, (seconds, nanos)|
      assert_equal @duration.new(seconds: seconds, nanos: nanos), all_types.new(optional_duration: value).optional_duration, value.inspect
    end
    m = all_types.new
    m.repeated_duration = [1, 2.5]
    assert_equal [@duration.new(seconds: 1), @duration.new(seconds: 2, nanos: 500_000_000)], m.repeated_duration
    [Float::INFINITY, Float::NAN, 10**12].each do |bad|
      error = assert_raises(Protostar::TypeError) { m.optional_duration = bad }
      assert_match(/expects a finite value in google.protobuf.Duration's range/, error.message)
    end
    assert_raises(Protostar::TypeError) { m.optional_duration = Time.now }
    assert_raises(Protostar::TypeError) { m.optional_timestamp = 5 }
  end

  def test_other_message_fields_take_no_ruby_values
    assert_raises(Protostar::TypeError) { all_types.new(optional_nested_message: Time.now) }
    assert_nil all_types.__coerce(Time.now)
  end

  private

  def proto3
    CodecFixtures.load("google/protobuf/test_messages_proto3.proto")
  end

  def all_types
    proto3["protobuf_test_messages.proto3.TestAllTypesProto3"]
  end
end
