# frozen_string_literal: true

require "test/unit"
require_relative "../isolation"

# The shim's tests run in parallel processes; nothing in them may share a
# temp path, a port or ENV with another
class IsolationTest < Test::Unit::TestCase
  TEST = File.expand_path("..", __dir__)
  EXEMPT = %w[isolation.rb shim/isolation_test.rb].freeze

  def test_temp_dirs_come_only_from_the_helper
    assert_equal [], grep(/Dir\.mktmpdir|Dir\.tmpdir|Tempfile|["'`](?:\/tmp|tmp)\//), "use Isolation.tmpdir"
  end

  def test_ports_come_from_the_os
    assert_equal [], grep(/TCPServer\.(?:new|open)|add_http2_port\("[^"]*:(?!0")\d+"/), "listen on port 0"
  end

  def test_env_is_never_written
    assert_equal [], grep(/ENV\[[^\]]+\]\s*(?:=[^=~]|\|\|=)|ENV\.(?:store|delete|update|merge!|replace|clear)\b/)
  end

  def test_tmpdir_is_per_process_and_goes_away
    made = Isolation.tmpdir { |dir| dir }
    assert_false File.exist?(made)
    assert_true made.start_with?(File.join(Isolation::ROOT, "tmp", "test", Process.pid.to_s, ""))
  end

  private

  def grep(pattern)
    Dir.glob("**/*.rb", base: TEST).sort.flat_map do |rel|
      next [] if EXEMPT.include?(rel)
      File.foreach(File.join(TEST, rel)).with_index(1).filter_map do |line, n|
        "test/#{rel}:#{n}: #{line.strip}" if pattern.match?(line)
      end
    end
  end
end
