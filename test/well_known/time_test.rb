# frozen_string_literal: true

require "test_helper"

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
end
