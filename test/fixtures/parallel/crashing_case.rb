# frozen_string_literal: true

require "test_helper"

# Run by test/parallel/runner_test.rb, never by rake test: the worker
# running it disappears halfway
class ParallelCrashingCase < Minitest::Test
  def test_takes_the_worker_down
    exit!(3)
  end
end
