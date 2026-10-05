# frozen_string_literal: true

require_relative "builder_support"

class BuilderCacheTest < Minitest::Test
  include BuilderSupport

  def setup
    @store = Store.new
    @runs = 0
  end

  def fragment(pb, name = "cached")
    @runs += 1
    pb.name name
    pb.address { pb.street "x" }
    pb.ids [1, 2]
  end

  def test_a_miss_runs_the_block_and_stores_its_bytes_a_hit_appends_them
    miss = build(cache_store: @store) do |pb|
      pb.id 1
      pb.cache!("person/1") { fragment(pb) }
      pb.nicknames ["after"]
    end
    expected = Person.new(id: 1, name: "cached", address: {street: "x"}, ids: [1, 2], nicknames: ["after"])
    assert_equal expected, decode(miss)
    assert_equal 1, @runs
    assert_equal Person.new(name: "cached", address: {street: "x"}, ids: [1, 2]).encode, @store.data["person/1"]
    assert_predicate @store.data["person/1"], :frozen?

    hit = build(cache_store: @store) do |pb|
      pb.id 1
      pb.cache!("person/1") { fragment(pb, "fresh") }
      pb.nicknames ["after"]
    end
    assert_equal 1, @runs
    assert_equal miss, hit
  end

  def test_keys_and_options_go_to_the_store_as_given
    key = ["person", 1]
    build(cache_store: @store) { |pb| pb.cache!(key, expires_in: 60) { fragment(pb) } }
    build(cache_store: @store) { |pb| pb.cache!(:plain) { fragment(pb) } }
    assert_equal [[key, {expires_in: 60}], [:plain, nil]], @store.fetches
  end

  def test_caching_inside_nested_messages_and_collections
    build_friends = ->(pb) do
      pb.friends([1, 2]) do |i|
        pb.id i
        pb.cache!("friend/#{i}") { fragment(pb, "f#{i}") }
      end
    end
    miss = build(cache_store: @store, &build_friends)
    hit = build(cache_store: @store, &build_friends)
    assert_equal 2, @runs
    assert_equal miss, hit
    assert_equal %w[f1 f2], decode(hit).friends.map(&:name)
  end

  def test_cache_if
    build(cache_store: @store) do |pb|
      pb.cache_if!(false, "k") { fragment(pb) }
    end
    assert_empty @store.data
    build(cache_store: @store) { |pb| pb.cache_if!(true, "k") { fragment(pb) } }
    assert_equal ["k"], @store.data.keys
  end

  def test_without_a_store_the_block_just_runs
    assert_equal Person.new(name: "cached", address: {street: "x"}, ids: [1, 2]).encode,
      build { |pb| pb.cache!("k") { fragment(pb) } }
  end

  def test_a_hit_counts_its_fields_as_written
    build(cache_store: @store) { |pb| pb.cache!("k") { fragment(pb) } }
    error = assert_raises(Protostar::Builder::Error) do
      build(cache_store: @store) do |pb|
        pb.cache!("k") { fragment(pb) }
        pb.name "again"
      end
    end
    assert_match(/name: is already set/, error.message)

    bytes = build(cache_store: @store, overwrites: true) do |pb|
      pb.cache!("k") { fragment(pb) }
      pb.name ""
    end
    assert_equal "", decode(bytes).name
  end

  def test_a_miss_counts_its_fields_as_written
    error = assert_raises(Protostar::Builder::Error) do
      build(cache_store: @store) do |pb|
        pb.name "first"
        pb.cache!("k") { fragment(pb) }
      end
    end
    assert_match(/name: is already set/, error.message)
  end

  def test_a_value_that_is_not_bytes
    @store.write("k", {"name" => "old pbbuilder entry"})
    error = assert_raises(Protostar::Builder::Error) { build(cache_store: @store) { |pb| pb.cache!("k") { fragment(pb) } } }
    assert_match(/cache store returned a Hash/, error.message)
    @store.write("k", "\xFF".b)
    error = assert_raises(Protostar::Builder::Error) { build(cache_store: @store) { |pb| pb.cache!("k") { fragment(pb) } } }
    assert_match(/cached fragment is not valid wire data/, error.message)
  end

  def test_streaming_with_a_cache
    io = StringIO.new(+"".b)
    Protostar::Builder.write(io, Person, cache_store: @store) { |pb| pb.cache!("k") { fragment(pb) } }
    Protostar::Builder.write(io, Person, cache_store: @store) { |pb| pb.cache!("k") { fragment(pb) } }
    one = Person.new(name: "cached", address: {street: "x"}, ids: [1, 2]).encode
    assert_equal one * 2, io.string
  end
end
