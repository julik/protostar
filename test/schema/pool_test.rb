# frozen_string_literal: true

require "test_helper"

class PoolTest < Minitest::Test
  S = Protostar::Schema

  def setup
    @pool = S::Pool.new
  end

  def build(hash)
    S::Builder.build(hash, pool: @pool)
  end

  def test_lookups
    file = @pool.add(build(name: "a.proto", package: "pkg",
      message_type: [{name: "M", extension_range: [{start: 10, end: 20}]}],
      enum_type: [{name: "E", value: [{name: "E_ZERO", number: 0}]}],
      service: [{name: "S", method: [{name: "Call", input_type: ".pkg.M", output_type: ".pkg.M"}]}],
      extension: [{name: "ext", number: 10, label: :LABEL_OPTIONAL, type: :TYPE_INT32, extendee: ".pkg.M"}]))
    assert_same file, @pool.file("a.proto")
    assert @pool.include?("a.proto")
    refute @pool.include?("b.proto")
    assert_equal [file], @pool.files
    assert_same file.messages.first, @pool.find_message("pkg.M")
    assert_nil @pool.find_message("pkg.E")
    assert_same file.enums.first, @pool.find_enum("pkg.E")
    assert_same file.services.first, @pool.find_service("pkg.S")
    assert_same file.services.first.rpc(:Call), @pool.find_symbol("pkg.S.Call")
    assert_same file.enums.first.value(0), @pool.find_symbol("pkg.E_ZERO")
    assert_same file.extensions.first, @pool.find_extension("pkg.M", 10)
    assert_same file.extensions.first, @pool.find_extension(file.messages.first, 10)
    assert_nil @pool.find_extension("pkg.M", 11)
    assert_equal [file.extensions.first], @pool.extensions_of("pkg.M")
    assert_equal [], @pool.extensions_of("pkg.Nothing")
    assert_nil @pool.find_symbol("pkg")
  end

  def test_building_does_not_add
    build(name: "a.proto")
    refute @pool.include?("a.proto")
  end

  def test_duplicate_file
    @pool.add(build(name: "a.proto"))
    error = assert_raises(S::Error) { @pool.add(build(name: "a.proto")) }
    assert_includes error.message, "already in the pool"
  end

  # AlreadyDefinedInOtherFile
  def test_symbol_defined_in_another_file
    @pool.add(build(name: "foo.proto", message_type: [{name: "Foo"}]))
    error = assert_raises(S::Error) { @pool.add(build(name: "bar.proto", message_type: [{name: "Foo"}])) }
    assert_includes error.message, "\"Foo\" is already defined in file \"foo.proto\""
    refute @pool.include?("bar.proto"), "a rejected file leaves no trace"
  end

  def test_enum_values_clash_in_the_enclosing_scope
    @pool.add(build(name: "a.proto", package: "p", enum_type: [{name: "A", value: [{name: "SAME", number: 0}]}]))
    assert_raises(S::Error) do
      @pool.add(build(name: "b.proto", package: "p", enum_type: [{name: "B", value: [{name: "SAME", number: 0}]}]))
    end
  end

  # PackageAlreadyDefined
  def test_package_clashing_with_a_symbol
    @pool.add(build(name: "foo.proto", message_type: [{name: "foo"}]))
    error = assert_raises(S::Error) { @pool.add(build(name: "bar.proto", package: "foo.bar")) }
    assert_includes error.message, "\"foo\" is already defined (as something other than a package) in file \"foo.proto\""
  end

  def test_symbol_clashing_with_a_package
    @pool.add(build(name: "pkg.proto", package: "foo.bar"))
    error = assert_raises(S::Error) { @pool.add(build(name: "foo.proto", package: "foo", message_type: [{name: "bar"}])) }
    assert_includes error.message, "already defined as a package"
  end

  def test_packages_may_be_shared
    @pool.add(build(name: "a.proto", package: "shared", message_type: [{name: "A"}]))
    @pool.add(build(name: "b.proto", package: "shared", message_type: [{name: "B"}]))
    assert_equal 2, @pool.files.size
  end

  def extension(name, number)
    {name: name, number: number, label: :LABEL_OPTIONAL, type: :TYPE_INT32, extendee: ".M"}
  end

  def test_extension_number_taken_by_another_file_warns_once_and_keeps_the_first
    @pool.add(build(name: "m.proto", message_type: [{name: "M", extension_range: [{start: 1, end: 100}]}]))
    a = @pool.add(build(name: "a.proto", dependency: ["m.proto"], extension: [extension("a", 5)]))
    b = nil
    _, err = capture_io do
      b = @pool.add(build(name: "b.proto", dependency: ["m.proto"], extension: [extension("b", 5), extension("c", 6)]))
    end
    assert_equal "b.proto: Extension number 5 has already been used in \"M\" by extension \"a\" defined in a.proto.\n", err
    assert_same b, @pool.file("b.proto")
    assert_same a.extensions.first, @pool.find_extension("M", 5)
    assert_equal %w[a c], @pool.extensions_of("M").map(&:name)
    _, err = capture_io do
      @pool.add(build(name: "c.proto", dependency: ["m.proto"], extension: [extension("d", 5)]), warn: false)
    end
    assert_empty err
  end

  def test_extension_number_taken_twice_in_one_file
    @pool.add(build(name: "m.proto", message_type: [{name: "M", extension_range: [{start: 1, end: 100}]}]))
    error = assert_raises(S::Error) do
      @pool.add(build(name: "a.proto", dependency: ["m.proto"], extension: [extension("a", 5), extension("b", 5)]))
    end
    assert_equal "extension number 5 of \"M\" is already used by \"a\" (redefined by \"b\")", error.message
    refute @pool.include?("a.proto")
  end

  def test_rejects_unbuilt_things
    assert_raises(S::Error) { @pool.add({name: "a.proto"}) }
  end

  def test_concurrent_add
    hashes = 64.times.map do |i|
      {name: "f#{i}.proto", package: "p#{i % 4}", message_type: [{name: "M#{i}"}],
       enum_type: [{name: "E#{i}", value: [{name: "V#{i}", number: 0}]}]}
    end
    files = hashes.map { |h| build(h) }
    threads = files.each_slice(8).map { |slice| Thread.new { slice.each { |f| @pool.add(f) } } }
    threads.each(&:join)
    assert_equal 64, @pool.files.size
    64.times { |i| assert_equal "M#{i}", @pool.find_message("p#{i % 4}.M#{i}").name }
  end

  def test_concurrent_add_of_clashing_files_admits_exactly_one
    files = 16.times.map { |i| build(name: "f#{i}.proto", message_type: [{name: "Same"}]) }
    errors = Queue.new
    files.map { |f| Thread.new { @pool.add(f) rescue errors << $! } }.each(&:join) # standard:disable Style/RescueModifier
    assert_equal 1, @pool.files.size
    assert_equal 15, errors.size
  end
end
