# frozen_string_literal: true

require_relative "builder_support"

class BuilderStreamingTest < Minitest::Test
  include BuilderSupport

  # Records each write, to see that bytes leave before the block ends
  class Recorder
    attr_reader :writes

    def initialize
      @writes = []
    end

    def write(bytes)
      @writes << bytes.dup
      bytes.bytesize
    end
  end

  def test_top_level_elements_stream_through_the_buffer
    io = Recorder.new
    seen = []
    Protostar::Builder.write(io, Person) do |pb|
      pb.friends(1..2000) do |i|
        pb.name "friend number #{i} #{"x" * 40}"
        seen << io.writes.size if i == 2000
      end
    end
    assert_operator seen.first, :>=, 1, "nothing was written before the last element"
    expected = Person.new(friends: (1..2000).map { |i| {name: "friend number #{i} #{"x" * 40}"} }).encode
    assert_equal expected, io.writes.join
    assert io.writes[0...-1].all? { |w| w.bytesize >= Protostar::Wire::Writer::FLUSH_AT }
  end

  def test_through_a_pipe
    reader, writer = IO.pipe
    reader.binmode
    writer.binmode
    consumer = Thread.new { reader.read }
    Protostar::Builder.write(writer, Person) do |pb|
      pb.name "piped"
      pb.friends(1..5000) { |i| pb.id i }
      pb.ids (1..100).to_a
    end
    writer.close
    expected = Person.new(name: "piped", friends: (1..5000).map { |i| {id: i} }, ids: (1..100).to_a)
    assert_equal expected, Person.decode(consumer.value)
  ensure
    reader&.close
  end
end
