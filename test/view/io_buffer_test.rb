# frozen_string_literal: true

require "test_helper"

class ViewIOBufferTest < Minitest::Test
  def setup
    @experimental = Warning[:experimental]
    Warning[:experimental] = false
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    @all = set["proto2_unittest.TestAllTypes"]
    @maps = CodecFixtures.load("google/protobuf/map_unittest.proto")["proto2_unittest.TestMap"]
  end

  def teardown
    Warning[:experimental] = @experimental
  end

  def test_reads_like_a_string_view
    random = Random.new(5)
    [@all, @maps].each do |klass|
      6.times do
        bytes = RandomMessage.build(klass, random: random, depth: 3, fill: 0.8).encode
        view = klass.view(IO::Buffer.for(bytes))
        assert_equal ViewSupport.plain(klass.decode(bytes).__to_h), ViewSupport.plain(view.to_h)
        assert_equal klass.decode(bytes), view.to_message
        assert_equal klass.decode(bytes).unknown_fields, view.unknown_fields
        assert_equal bytes, view.encode
      end
    end
  end

  def test_every_fixed_width_kind
    message = @all.new(
      optional_fixed32: 2**32 - 1, optional_fixed64: 2**64 - 1, optional_sfixed32: -2**31, optional_sfixed64: -2**63,
      optional_float: -1.5, optional_double: Float::INFINITY,
      repeated_fixed32: [1, 2], repeated_double: [0.5, -0.0], repeated_float: [Float::NAN]
    )
    view = @all.view(IO::Buffer.for(message.encode))
    assert_equal [2**32 - 1, 2**64 - 1, -2**31, -2**63, -1.5, Float::INFINITY],
      %i[optional_fixed32 optional_fixed64 optional_sfixed32 optional_sfixed64 optional_float optional_double].map { |f| view[f] }
    assert_equal [0.5, -0.0], view.repeated_double.to_a
    assert_equal(-0.0.to_s, view.repeated_double[1].to_s)
    assert_predicate view.repeated_float[0], :nan?
    assert_equal message, view.to_message
  end

  def test_offset_and_length_into_a_buffer
    bytes = @all.new(optional_string: "inner", optional_nested_message: {bb: 3}).encode
    buffer = IO::Buffer.new(bytes.bytesize + 10)
    buffer.set_string(bytes, 4)
    view = @all.view(buffer, offset: 4, length: bytes.bytesize)
    assert_equal "inner", view.optional_string
    assert_equal 3, view.optional_nested_message.bb
    assert_equal bytes, view.encode
    assert_raises(ArgumentError) { @all.view(buffer, offset: 11, length: bytes.bytesize) }
  end

  def test_mapped_file
    bytes = @all.new(optional_int32: 77, repeated_string: %w[from a file], optional_foreign_message: {c: 1}).encode
    tmpdir do |dir|
      path = File.join(dir, "view.binpb")
      File.binwrite(path, bytes)
      File.open(path, "rb") do |io|
        buffer = IO::Buffer.map(io, nil, 0, IO::Buffer::READONLY)
        view = @all.view(buffer)
        assert_equal 77, view.optional_int32
        assert_equal %w[from a file], view.repeated_string.to_a
        assert_equal 1, view.optional_foreign_message.c
        assert_equal @all.decode(bytes), view.to_message
      ensure
        buffer&.free
      end
    end
  end

  def test_locked_buffer
    bytes = @all.new(optional_int32: 3).encode
    buffer = IO::Buffer.for(bytes)
    buffer.locked do
      assert_equal 3, @all.view(buffer).optional_int32
    end
  end

  # IO::Buffer cannot be made shareable on any Ruby we support, so neither can its views
  def test_io_buffer_views_are_not_shareable
    view = @all.view(IO::Buffer.for(@all.new(optional_int32: 1).encode.freeze)).freeze_index
    refute Ractor.shareable?(view)
    assert_equal 1, view.optional_int32
  end

  def test_malformed_buffer
    error = assert_raises(Protostar::DecodeError) { @all.view(IO::Buffer.for("\x72\x05abc".b)) }
    assert_equal 2, error.offset
  end
end
