# frozen_string_literal: true

require_relative "builder_support"
require "objspace"
require "stringio"

# chunk_nested_at, DELIMITED fields, and sequences: what streams, and that
# readers put the pieces back together
class BuilderChunkingTest < Minitest::Test
  include BuilderSupport

  LINE = ("x" * 1021).freeze # 1 KiB with tag and length

  # Counts bytes, keeps nothing
  class Counter
    attr_reader :bytes, :writes

    def initialize(&on_write)
      @bytes = 0
      @writes = 0
      @on_write = on_write
    end

    def write(s)
      @on_write&.call(s)
      @bytes += s.bytesize
      @writes += 1
      s.bytesize
    end
  end

  # [field number, value bytes] of every top-level field
  def fields(bytes)
    r = Protostar::Wire::Reader.new(bytes)
    out = []
    until r.eof?
      number, wire_type = r.read_tag
      start = r.pos
      r.skip_field(number, wire_type)
      out << [number, bytes.byteslice(start, r.pos - start)]
    end
    out
  end

  def lines(pb, n, line = "l" * 50)
    n.times { pb.lines line }
  end

  def test_a_nested_message_past_the_size_is_written_in_pieces
    plain = Protostar::Builder.build(Root) { |pb| pb.node { lines(pb, 100) } }
    chunked = Protostar::Builder.build(Root, chunk_nested_at: 256) { |pb| pb.node { lines(pb, 100) } }
    pieces = fields(chunked)
    assert_equal [2], pieces.map(&:first).uniq
    assert_equal 20, pieces.size # 5 lines of 52 bytes per piece
    refute_equal plain, chunked
    assert_equal Root.decode(plain), Root.decode(chunked)
  end

  def test_pieces_cascade_outwards_through_nested_messages
    build = lambda do |**o|
      Protostar::Builder.build(Root, **o) do |pb|
        pb.name "r"
        pb.node do
          pb.text "t"
          pb.child { pb.child { lines(pb, 60) } }
        end
      end
    end
    chunked = build.call(chunk_nested_at: 200)
    assert_operator fields(chunked).count { |n, _| n == 2 }, :>, 10
    assert_equal Root.decode(build.call), Root.decode(chunked)
  end

  def test_scalars_and_packed_runs_keep_their_order_across_pieces
    build = lambda do |**o|
      Protostar::Builder.build(Root, **o) do |pb|
        pb.node do
          pb.text "first"
          20.times do |i|
            pb.nums [i, i + 100]
            pb.lines "line #{i}"
          end
        end
      end
    end
    chunked = build.call(chunk_nested_at: 16)
    assert_equal 10, fields(chunked).size # two 8-byte lines per piece, the packed runs with them
    node = Root.decode(chunked).node
    assert_equal 20.times.flat_map { |i| [i, i + 100] }, node.nums.to_a
    assert_equal 20.times.map { |i| "line #{i}" }, node.lines.to_a
    assert_equal "first", node.text
    assert_equal Root.decode(build.call), Root.decode(chunked)
  end

  def test_repeated_elements_and_map_values_are_never_split
    chunked = Protostar::Builder.build(Root, chunk_nested_at: 64) do |pb|
      pb.nodes([1, 2]) { |i| lines(pb, 10 * i) }
      pb.node { pb.named("k" => {lines: Array.new(10, "v" * 50)}) }
    end
    top = fields(chunked)
    assert_equal 2, top.count { |n, _| n == 3 }
    node = top.find { |n, _| n == 2 }[1]
    assert_equal 1, fields(node.byteslice(Protostar::Wire.varint_size(node.bytesize)..)).count { |n, _| n == 6 }
    decoded = Root.decode(chunked)
    assert_equal [10, 20], decoded.nodes.map { |n| n.lines.size }
    assert_equal 10, decoded.node.named["k"].lines.size
  end

  def test_but_a_message_inside_a_repeated_element_is
    chunked = Protostar::Builder.build(Root, chunk_nested_at: 64) do |pb|
      pb.nodes([1]) { pb.child { lines(pb, 10) } }
    end
    element = fields(chunked).first[1]
    inner = fields(element.byteslice(Protostar::Wire.varint_size(element.bytesize)..))
    assert_operator inner.count { |n, _| n == 2 }, :>, 1
    assert_equal 10, Root.decode(chunked).nodes[0].child.lines.size
  end

  def test_oneof_members_and_groups_inside_pieces
    build = lambda do |**o|
      Protostar::Builder.build(Root, **o) do |pb|
        pb.node do
          pb.left { lines(pb, 20) }
          pb.flat do
            pb.child { lines(pb, 20) }
            lines(pb, 5)
          end
          lines(pb, 5)
        end
      end
    end
    chunked = build.call(chunk_nested_at: 64)
    assert_operator fields(chunked).size, :>, 5
    assert_equal Root.decode(build.call), Root.decode(chunked)
    assert_equal 20, Root.decode(chunked).node.left.lines.size
  end

  def test_cached_fragments_stay_whole
    store = Store.new
    2.times do
      chunked = Protostar::Builder.build(Root, chunk_nested_at: 32, cache_store: store) do |pb|
        pb.node do
          pb.text "t"
          pb.cache!("frag") { pb.child { lines(pb, 10) } }
          lines(pb, 3)
        end
      end
      assert_equal 10, Root.decode(chunked).node.child.lines.size
      assert_equal 3, Root.decode(chunked).node.lines.size
    end
    assert_equal 1, fields(store.data.fetch("frag")).size
  end

  def test_chunking_needs_the_no_overwrites_promise
    error = assert_raises(ArgumentError) { Protostar::Builder.new(Root, nil, chunk_nested_at: 1024, overwrites: true) }
    assert_match(/needs overwrites: false and repeated: :append/, error.message)
    assert_raises(ArgumentError) { Protostar::Builder.new(Root, nil, chunk_nested_at: 1024, repeated: :replace) }
    assert_raises(ArgumentError) { Protostar::Builder.new(Root, nil, chunk_nested_at: 0) }
  end

  def test_a_second_write_raises_across_pieces
    error = assert_raises(Protostar::Builder::Error) do
      Protostar::Builder.write(Counter.new, Root, chunk_nested_at: 64) do |pb|
        pb.node do
          pb.text "a"
          lines(pb, 50)
          pb.text "b"
        end
      end
    end
    assert_equal "node.text", error.path
    assert_includes error.message, "overwrites: false"
  end

  def test_delimited_fields_stream_without_a_buffer
    seen = nil
    sink = Counter.new
    Protostar::Builder.write(sink, Root, buffer: 1024) do |pb|
      pb.flat do
        pb.child { lines(pb, 5) }
        lines(pb, 200)
        seen = sink.writes
      end
    end
    assert_operator seen, :>, 5
    assert_equal sink.bytes, Root.new(flat: {child: {lines: Array.new(5, "l" * 50)}, lines: Array.new(200, "l" * 50)}).encode.bytesize
  end

  def test_held_memory_is_bounded_by_the_chunk_size
    size = 20 * 1024 # lines of 1 KiB, 20 MB
    chunked = held_peak do |sample|
      sink = Counter.new { |s| sample.call if s.bytesize >= 1_048_576 }
      Protostar::Builder.write(sink, Root, chunk_nested_at: 65_536) do |pb|
        pb.node { pb.child { size.times { |i| pb.lines(LINE) && (i % 2048 == 2047) && sample.call } } }
      end
      assert_operator sink.bytes, :>, 20 * 1_048_576
    end
    whole = held_peak do |sample|
      sink = Counter.new { |s| sample.call if s.bytesize >= 1_048_576 }
      Protostar::Builder.write(sink, Root) do |pb|
        pb.node { pb.child { size.times { |i| pb.lines(LINE) && (i % 2048 == 2047) && sample.call } } }
      end
    end
    assert_operator chunked, :<, 1_048_576, "held #{chunked} bytes with chunk_nested_at: 65_536"
    assert_operator whole, :>, 19 * 1_048_576, "held #{whole} bytes without chunking"
  end

  def test_each_writes_length_prefixed_messages
    rows = (1..50).map { |i| "row #{i}" }
    io = StringIO.new(+"".b)
    assert_same io, Protostar::Builder.each(io, Root, rows) { |pb, row| pb.node { pb.text row }.name(row) }
    io.rewind
    read = []
    while (m = Root.decode_delimited(io))
      read << m
    end
    assert_equal rows.map { |r| Root.new(name: r, node: {text: r}) }, read
    bytes = Protostar::Builder.each(nil, Root, rows) { |pb, row| pb.node { pb.text row }.name(row) }
    assert_equal rows.map { |r| Root.new(name: r, node: {text: r}).encode_delimited }.join, bytes
    assert_equal Root.new(name: "row 1", node: {text: "row 1"}), Root.decode_delimited(bytes)
  end

  def test_each_sends_each_message_as_it_completes_with_buffer_zero
    chunks = []
    Protostar::Builder.each(chunks, Root, 1..3, buffer: 0) do |pb, i|
      pb.name "n#{i}"
      assert_equal i - 1, chunks.size
    end
    assert_equal (1..3).map { |i| Root.new(name: "n#{i}").encode_delimited }, chunks
    error = assert_raises(Protostar::Builder::Error) { Protostar::Builder.each(chunks, Root, [1, 2]) { |pb, i| pb.name("x").name("y") if i == 2 } }
    assert_equal "[1].name", error.path
    assert_raises(ArgumentError) { Protostar::Builder.each(chunks, Root, 3) { |_, _| } }
  end

  def test_each_chunk_is_a_lazy_enumerator
    ran = 0
    body = Protostar::Builder.each_chunk(Root, buffer: 1024) do |pb|
      ran += 1
      lines(pb, 100)
    end
    assert_kind_of Enumerator, body
    assert_equal 0, ran
    chunks = body.to_a
    assert_equal 1, ran
    assert_operator chunks.size, :>, 3
    assert chunks.all? { |c| c.encoding == Encoding::BINARY }
    assert_equal Root.new(lines: Array.new(100, "l" * 50)).encode, chunks.join
    assert_equal chunks.first, body.next
    assert_raises(ArgumentError) { Protostar::Builder.each_chunk(Root) }
  end

  # Decode equality across readers: ours and google-protobuf's, for random
  # messages of the corpus built with every nested message split at every field
  ORACLE_FILES = %w[
    google/protobuf/unittest.proto
    google/protobuf/unittest_proto3.proto
    google/protobuf/map_unittest.proto
    google/protobuf/unittest_delimited.proto
    google/protobuf/edition_unittest.proto
  ].freeze

  def test_chunked_bytes_decode_the_same_in_google_protobuf
    skip "set PROTOSTAR_ORACLE=1 with BUNDLE_WITH=oracle to cross-check against google-protobuf" unless Oracle.available?
    checked = 0
    ORACLE_FILES.each do |relative|
      set = CodecFixtures.load(relative)
      pool = Oracle.pool(relative)
      random = Random.new(relative.sum + 5)
      set.file.all_messages.each do |descriptor|
        next if descriptor.map_entry?
        klass = set[descriptor.full_name]
        oracle = pool.lookup(descriptor.full_name).msgclass
        3.times do |n|
          message = RandomMessage.build(klass, random: random, depth: 3, fill: (n == 0) ? 1.0 : 0.5, unknown: false)
          hash = message.__to_h
          [1, 24].each do |at|
            chunked = Protostar::Builder.build(klass, chunk_nested_at: at) { |pb| BuilderSupport.replay(pb, klass, hash) }
            assert_equal message, klass.decode(chunked), "ours, #{descriptor.full_name}, chunk_nested_at: #{at}"
            assert_equal normalize(oracle.decode(message.encode).to_h), normalize(oracle.decode(chunked).to_h),
              "google-protobuf, #{descriptor.full_name}, chunk_nested_at: #{at}"
            checked += 1
          end
        end
      end
    end
    assert_operator checked, :>, 500
  end

  private

  # The peak of String and Array memory over the samples taken, after a full GC each time
  def held_peak
    measure = -> { ObjectSpace.memsize_of_all(String) + ObjectSpace.memsize_of_all(Array) }
    GC.start
    base = measure.call
    peak = 0
    sample = lambda do
      GC.start
      held = measure.call - base
      peak = held if held > peak
    end
    yield sample
    peak
  end

  def normalize(value)
    case value
    when Hash then value.to_h { |k, v| [normalize(k), normalize(v)] }
    when Array then value.map { |v| normalize(v) }
    when Float then value.nan? ? :NaN : value
    when String then value.b
    else value
    end
  end
end
