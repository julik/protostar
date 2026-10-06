# frozen_string_literal: true

require "test_helper"

# Run by test/parallel/runner_test.rb, never by rake test
class ParallelFailingCase < Minitest::Test
  # Marshal refuses a Proc, so the worker has to send this one as plain text
  class Unsendable < StandardError
    def initialize
      super("cannot be marshalled")
      @callback = -> {}
    end
  end

  def test_fails
    assert_equal 1, 2
  end

  def test_errors_with_something_marshal_refuses
    raise Unsendable
  end

  def test_passes
    assert true
  end
end
