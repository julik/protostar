# frozen_string_literal: true

require_relative "builder_support"
require "stringio"
require "zlib"

# Every kind of sink, every buffer size: the same bytes, binary, in the order written
class BuilderSinksTest < Minitest::Test
  include BuilderSupport

  # Keeps what it is given, as an ActionController::Live stream does
  class Keeper
    attr_reader :chunks, :flushes

    def initialize
      @chunks = []
      @flushes = 0
    end

    def write(bytes)
      @chunks << bytes
      bytes.bytesize
    end

    def flush
      @flushes += 1
    end
  end

  # Takes bytes with << only
  class Appender
    attr_reader :chunks

    def initialize
      @chunks = []
    end

    def <<(bytes)
      @chunks << bytes
      self
    end
  end

  # Fails on the nth write
  class Broken
    def initialize(after)
      @after = after
    end

    def write(bytes)
      raise Errno::EPIPE, "the reader went away" if (@after -= 1) < 0
      bytes.bytesize
    end
  end

  BIG = "y" * 70_000

  def block
    proc do |pb|
      pb.name "top"
      pb.id 7
      pb.friends(1..3) do |i|
        pb.name "friend #{i}"
        pb.ids [i, i + 1]
        pb.address { pb.street BIG } if i == 2
      end
      pb.address { pb.city "x" * 200 }
      pb.attrs("a" => "b", "c" => "d")
      pb.nicknames ["é", "日本"]
      pb.kinds %i[KIND_A KIND_B]
    end
  end

  def expected
    @expected ||= Protostar::Builder.build(Person, &block)
  end

  def sinks
    {
      "String" => [-> { +"" }, ->(s) { s }],
      "StringIO" => [-> { StringIO.new }, ->(s) { s.string }],
      "Array" => [-> { [] }, ->(s) { s.join }],
      "Proc" => [-> { [] }, ->(s) { s.join }, ->(list) { ->(bytes) { list << bytes } }],
      "write keeper" => [-> { Keeper.new }, ->(s) { s.chunks.join }],
      "<< appender" => [-> { Appender.new }, ->(s) { s.chunks.join }],
      "File" => [-> { File.open(File.join(tmpdir, "out.bin"), "wb") }, ->(s) { s.close || File.binread(s.path) }],
      "pipe" => [-> { pipe }, ->(s) { s.close || @consumer.value }],
      "GzipWriter" => [-> { Zlib::GzipWriter.new(StringIO.new(+"")) }, ->(s) { Zlib.gunzip(s.finish.string) }]
    }
  end

  def pipe
    reader, writer = IO.pipe
    reader.binmode
    writer.binmode
    @consumer = Thread.new do
      reader.read
    ensure
      reader.close
    end
    writer
  end

  def test_every_sink_and_buffer_size_gets_the_same_bytes
    [0, 1, 7, 4096, 65_536, nil].each do |buffer|
      options = buffer ? {buffer: buffer} : {}
      sinks.each do |name, (make, read, wrap)|
        sink = make.call
        target = wrap ? wrap.call(sink) : sink
        result = Protostar::Builder.write(target, Person, **options, &block)
        assert_same target, result
        assert_equal expected, read.call(sink).b, "#{name}, buffer: #{buffer.inspect}"
      end
    end
  end

  def test_chunks_are_binary_and_kept_chunks_stay_intact
    keeper = Keeper.new
    Protostar::Builder.write(keeper, Person, buffer: 16, &block)
    assert_operator keeper.chunks.size, :>, 5
    assert keeper.chunks.all? { |c| c.encoding == Encoding::BINARY }
    assert_equal expected, keeper.chunks.join
    assert_equal 1, keeper.flushes
  end

  def test_a_string_sink_is_switched_to_binary
    out = +"prefix é"
    Protostar::Builder.write(out, Person) { |pb| pb.name "日本" }
    assert_equal Encoding::BINARY, out.encoding
    assert_equal "prefix é".b + Person.new(name: "日本").encode, out
  end

  def test_buffer_zero_writes_each_top_level_field_as_it_completes
    seen = []
    keeper = Keeper.new
    Protostar::Builder.write(keeper, Person, buffer: 0) do |pb|
      pb.name "a"
      seen << keeper.chunks.size
      pb.id 300
      seen << keeper.chunks.size
      pb.address { pb.street "s" }
      seen << keeper.chunks.size
      pb.nicknames ["x", "y"]
      seen << keeper.chunks.size
      pb.ids [1, 2]
      seen << keeper.chunks.size
    end
    assert_equal [1, 2, 3, 5, 5], seen
    expected = [{name: "a"}, {id: 300}, {address: {street: "s"}}, {nicknames: ["x"]}, {nicknames: ["y"]}, {ids: [1, 2]}]
    assert_equal expected.map { |h| Person.new(**h).encode }, keeper.chunks
  end

  def test_a_nested_message_larger_than_the_buffer_goes_to_the_sink_whole
    keeper = Keeper.new
    Protostar::Builder.write(keeper, Person) do |pb|
      pb.name "n"
      pb.address { pb.street BIG }
    end
    # name, address's tag and length through the buffer; address's 70,004 bytes as they are
    assert_equal [3 + 4, 70_004], keeper.chunks.map(&:bytesize)
    assert_equal Person.new(name: "n", address: {street: BIG}).encode, keeper.chunks.join
    io = StringIO.new
    Protostar::Builder.write(io, Person) { |pb| pb.address { pb.street BIG } }
    assert_equal Person.new(address: {street: BIG}).encode, io.string.b
  end

  def test_large_top_level_scalar_runs_stream_too
    keeper = Keeper.new
    Protostar::Builder.write(keeper, Root, buffer: 1024) do |pb|
      pb.loose Array.new(5000, 300)
      assert_operator keeper.chunks.size, :>, 5
    end
    assert_equal Root.new(loose: Array.new(5000, 300)), Root.decode(keeper.chunks.join)
  end

  def test_a_large_packed_run_is_held_as_bytes_and_written_whole
    keeper = Keeper.new
    values = Array.new(40_000) { |i| i * 7 - 1000 }
    Protostar::Builder.write(keeper, Root) do |pb|
      pb.name "n"
      values.each_slice(1000) { |s| pb.nums s }
    end
    assert_equal Root.new(name: "n", nums: values), Root.decode(keeper.chunks.join)
    assert_equal 2, keeper.chunks.size
    assert_operator keeper.chunks.last.bytesize, :>, 65_536
  end

  def test_not_a_sink
    error = assert_raises(ArgumentError) { Protostar::Builder.write(Object.new, Person) { |pb| pb.name "x" } }
    assert_equal "Object is not a sink: it answers none of write, << and call", error.message
    assert_raises(ArgumentError) { Protostar::Builder.new(Person, nil, buffer: -1) }
    assert_raises(ArgumentError) { Protostar::Builder.new(Person, nil, buffer: "big") }
  end

  def test_a_failing_sink_says_which_field_was_being_written
    error = assert_raises(Errno::EPIPE) do
      Protostar::Builder.write(Broken.new(2), Person, buffer: 0) do |pb|
        pb.name "a"
        pb.friends(1..5) { |i| pb.name "f#{i}" }
      end
    end
    assert_match(/the reader went away \(while writing friends\[1\]\)\z/, error.message)
    error = assert_raises(Errno::EPIPE) do
      Protostar::Builder.write(Broken.new(0), Person, buffer: 0) { |pb| pb.name "a" }
    end
    assert_match(/\(while writing the top level of buildertest.Person\)\z/, error.message)
    error = assert_raises(Errno::EPIPE) do
      Protostar::Builder.write(Broken.new(1), Root, chunk_nested_at: 64, buffer: 0) do |pb|
        pb.node { pb.child { pb.lines Array.new(10, "z" * 50) } }
      end
    end
    assert_match(/\(while writing node.child\)\z/, error.message)
  end

  def test_a_failing_flush_says_so_too
    sink = Keeper.new
    def sink.flush = raise(IOError, "closed stream")
    error = assert_raises(IOError) { Protostar::Builder.write(sink, Person) { |pb| pb.name "a" } }
    assert_equal "closed stream (while writing the top level of buildertest.Person)", error.message
  end

  def test_overwrites_raise_in_every_streaming_mode
    modes = {
      "build" => ->(&b) { Protostar::Builder.build(Person, &b) },
      "write, buffer: 0" => ->(&b) { Protostar::Builder.write(Keeper.new, Person, buffer: 0, &b) },
      "write to a Proc" => ->(&b) { Protostar::Builder.write(->(_) {}, Person, &b) },
      "chunk_nested_at" => ->(&b) { Protostar::Builder.write(StringIO.new, Person, chunk_nested_at: 1, &b) },
      "each" => ->(&b) { Protostar::Builder.each(StringIO.new, Person, [1]) { |pb, _| b.call(pb) } },
      "each_chunk" => ->(&b) { Protostar::Builder.each_chunk(Person, &b).to_a }
    }
    modes.each do |name, mode|
      prefix = (name == "each") ? "[0]." : ""
      error = assert_raises(Protostar::Builder::Error, name) { mode.call { |pb| pb.address { pb.street("a").street("b") } } }
      assert_equal "#{prefix}address.street: is already set; #{Protostar::Builder::NO_OVERWRITES} the last value win", error.message, name
      error = assert_raises(Protostar::Builder::Error, name) { mode.call { |pb| pb.email("a").phone("b") } }
      assert_equal "#{prefix}phone", error.path, name
      assert_includes error.message, "overwrites: true", name
    end
  end
end
