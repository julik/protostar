# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require_relative "../parallel" unless defined?(ParallelTests)

# test/parallel.rb: the shards it makes, the timings it keeps, and a run of
# the fixture cases giving the same counts as the serial runner
class ParallelRunnerTest < Minitest::Test
  ROOT = ParallelTests::ROOT
  FIXTURES = %w[test/fixtures/parallel/passing_case.rb test/fixtures/parallel/failing_case.rb].freeze
  COUNTS = /(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/

  def test_longest_files_are_spread_first
    timings = {"a" => 10.0, "b" => 9.0, "c" => 6.0, "d" => 4.0, "e" => 1.0}
    shards = ParallelTests.shards(timings.keys, 2, timings)
    assert_equal [%w[a d e], %w[b c]], shards
  end

  def test_ractor_tests_get_a_worker_of_their_own
    files = %w[test/codec/ractor_test.rb test/json/ractor_test.rb test/codec/encode_test.rb test/view/api_test.rb
      test/codec/other_ractor_test.rb]
    shards = ParallelTests.shards(files, 2, files.to_h { |f| [f, 1.0] })
    assert_equal %w[test/codec/ractor_test.rb test/json/ractor_test.rb test/codec/other_ractor_test.rb], shards.last
    assert_equal 3, shards.size
    assert_equal %w[test/codec/encode_test.rb test/view/api_test.rb], shards[0..1].flatten.sort
  end

  def test_never_more_workers_than_files
    assert_equal [%w[test/view/api_test.rb]], ParallelTests.shards(%w[test/view/api_test.rb], 10)
  end

  def test_files_without_a_timing_are_weighed_by_size
    timings = {"test/view/api_test.rb" => 100.0}
    assert_equal 100.0, ParallelTests.weight("test/view/api_test.rb", timings)
    size = File.size(File.join(ROOT, "test/codec/encode_test.rb"))
    assert_in_delta size * ParallelTests::GUESS, ParallelTests.weight("test/codec/encode_test.rb", timings)
  end

  def test_timings_round_trip
    path = File.join(tmpdir, "timings")
    ParallelTests.write_timings({"test/b_test.rb" => 2.5, "test/a_test.rb" => 0.1234}, path)
    assert_equal "0.123 test/a_test.rb\n2.500 test/b_test.rb\n", File.read(path)
    assert_equal({"test/a_test.rb" => 0.123, "test/b_test.rb" => 2.5}, ParallelTests.read_timings(path))
    assert_equal({}, ParallelTests.read_timings(File.join(tmpdir, "missing")))
  end

  def test_parallel_and_serial_runs_count_the_same
    serial, = run_serial(FIXTURES)
    timings = File.join(tmpdir, "timings")
    parallel, out = run_parallel(FIXTURES, timings: timings)
    assert_equal [9, 7, 1, 1, 1], parallel, out
    assert_equal serial, parallel, out
    assert_includes out, "Expected: 1\n  Actual: 2"
    assert_includes out, "ParallelFailingCase::Unsendable: cannot be marshalled"
    assert_equal FIXTURES.sort, ParallelTests.read_timings(timings).keys
  end

  def test_a_worker_that_dies_is_an_error
    files = FIXTURES + %w[test/fixtures/parallel/crashing_case.rb]
    timings = File.join(tmpdir, "timings")
    counts, out = run_parallel(files, timings: timings, jobs: 3)
    assert_equal [10, 7, 1, 2, 1], counts, out
    assert_includes out, "a worker running test/fixtures/parallel/crashing_case.rb stopped before reporting every test"
    refute File.exist?(timings), "an incomplete run writes no timings"
  end

  private

  def run_serial(files)
    requires = files.map { |f| "require #{File.join(ROOT, f).inspect}" }.join(";")
    capture(RbConfig.ruby, "-I#{ROOT}/lib", "-I#{ROOT}/test", "-e", requires)
  end

  def run_parallel(files, timings:, jobs: 2)
    capture({"JOBS" => jobs.to_s, "PARALLEL_TIMINGS" => timings},
      RbConfig.ruby, "-I#{ROOT}/lib", "-I#{ROOT}/test", File.join(ROOT, "test", "parallel.rb"), *files, "--", "--seed", "1")
  end

  def capture(*command)
    out, status = Open3.capture2e(*command, chdir: ROOT)
    refute status.success?, "the fixtures fail on purpose:\n#{out}"
    counts = COUNTS.match(out)
    assert counts, out
    [counts.captures.map(&:to_i), out]
  end
end
