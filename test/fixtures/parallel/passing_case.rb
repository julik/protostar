# frozen_string_literal: true

require "test_helper"

# Run by test/parallel/runner_test.rb, never by rake test
class ParallelPassingCase < Minitest::Test
  5.times do |i|
    define_method(:"test_passes_#{i}") { assert_equal i, i }
  end

  def test_skips
    skip "on purpose"
  end
end
