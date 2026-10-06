# frozen_string_literal: true

# What loading a schema costs at boot: defining the message classes of
# unittest.proto and its three imports (88 messages and enums with their
# accessors, codecs and views), and the two ways descriptors arrive without
# the compiler. google-protobuf's row is add_serialized_file of the same four
# files plus a msgclass lookup of every message, which is what its generated
# code does.
#
#   ruby bench/definition_bench.rb
#   BENCH_SIDE=google ruby bench/definition_bench.rb

require_relative "bench"
require_relative "fixtures"

# Loads generated Ruby into a pool and registry of its own, so it can run again
module BenchDSL
  class << self
    attr_accessor :pool, :registry
  end

  def self.file(*args, **kwargs, &block)
    Protostar::DSL.file(*args, **kwargs, pool: pool, registry: registry, &block)
  end
end

Bench.section "Loading a schema" do |s|
  name = "google/protobuf/unittest.proto"
  roots = Corpus::INCLUDE_ROOTS
  files = Protostar::Compiler.new(include_paths: roots).compile([name], source_info: false)
  bytes = files.map(&:serialize)
  walk = ->(m) { m.map_entry? ? [] : [m.full_name] + m.nested_messages.flat_map(&walk) }
  names = files.flat_map { |f| f.messages.flat_map(&walk) }

  s.row("define classes, unittest.proto and 3 imports (#{names.size} message classes)") do
    registry = Protostar::Types::Registry.new
    files.each { |f| registry.define(f) }
  end

  emitter = Protostar::Compiler::Emitters::Ruby.new
  blocks = files.map do |f|
    emitter.file(f)[/^Protostar::DSL\.file.*?^end$/m].sub("Protostar::DSL.file(", "BenchDSL.file(")
  end
  s.row("load the generated Ruby (the DSL) and define classes, same files") do
    BenchDSL.pool = Protostar::Schema::Pool.new
    BenchDSL.registry = Protostar::Types::Registry.new
    blocks.each { |b| eval(b) } # standard:disable Security/Eval
  end
  s.row("Pool#add_serialized_file, same files, no classes") do
    pool = Protostar::Schema::Pool.new
    bytes.each { |b| pool.add_serialized_file(b) }
  end

  s.setup(side: :google) do
    require "google/protobuf"
    s.row("define classes, unittest.proto and 3 imports (#{names.size} message classes)", side: :google) do
      pool = Google::Protobuf::DescriptorPool.new
      bytes.each { |b| pool.add_serialized_file(b) }
      names.each { |n| pool.lookup(n).msgclass }
    end
  end
end
