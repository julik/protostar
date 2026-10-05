# frozen_string_literal: true

require "test_helper"
require "objspace"

# Reading one field of a large message copies nothing but that field
class ViewNoCopyTest < Minitest::Test
  def setup
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = set["proto2_unittest.TestAllTypes"]
    filler = "x" * 1024
    @bytes = @all.new(
      optional_int32: 1,
      optional_bytes: "y" * (512 * 1024),
      repeated_string: Array.new(512) { filler },
      optional_nested_message: {bb: 42},
      repeated_nested_message: Array.new(1000) { |i| {bb: i} },
      optional_foreign_message: {c: 9}
    ).encode.freeze
    assert_operator @bytes.bytesize, :>, 1024 * 1024
  end

  def test_reading_a_nested_scalar_allocates_no_long_string
    strings, objects = allocations { @all.view(@bytes).optional_nested_message.bb }
    assert_empty strings, "strings longer than 8 bytes: #{strings.map(&:bytesize)}"
    assert_operator objects, :<, 20
  end

  def test_reading_an_element_of_a_large_repeated_field_allocates_no_long_string
    strings, = allocations { @all.view(@bytes).repeated_nested_message[999].bb }
    assert_empty strings, "strings longer than 8 bytes: #{strings.map(&:bytesize)}"
  end

  def test_reading_a_string_copies_only_that_string
    strings, = allocations { @all.view(@bytes).repeated_string[3] }
    assert_equal [1024], strings.map(&:bytesize)
  end

  def test_io_buffer_reads_in_place
    Warning[:experimental] = false
    buffer = IO::Buffer.for(@bytes)
    strings, = allocations { @all.view(buffer).optional_foreign_message.c }
    assert_empty strings, "strings longer than 8 bytes: #{strings.map(&:bytesize)}"
  end

  private

  # @return [Array(Array<String>, Integer)] Strings over 8 bytes allocated
  #   by the block, and how many objects it allocated in all
  def allocations
    GC.start
    GC.disable
    # One untraced warm-up run, then the count: the tracer's own bookkeeping and
    # first-call method caches are not what we are measuring (Ruby 4.0.7 showed
    # 54 objects for a read that costs 9)
    yield
    before = GC.stat(:total_allocated_objects)
    yield
    count = GC.stat(:total_allocated_objects) - before
    ObjectSpace.trace_object_allocations { yield }
    strings = ObjectSpace.each_object(String).select do |s|
      ObjectSpace.allocation_sourcefile(s) && s.bytesize > 8 && !ObjectSpace.allocation_sourcefile(s).end_with?("_test.rb")
    end
    [strings, count]
  ensure
    ObjectSpace.trace_object_allocations_clear
    GC.enable
  end
end
