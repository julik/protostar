# frozen_string_literal: true

# The compiler numbers of docs/compiler-internals.md section 21, plus the
# runtime paths that build descriptors without the compiler: loading a
# generated `_pb.rb` (the DSL), `add_serialized_file` and `to_proto`.
# Best of N wall-clock runs, in milliseconds.
#
#   bundle exec ruby bench/compiler_bench.rb
#   bundle exec ruby bench/compiler_bench.rb corpus   # adds the whole-corpus rows (slow)

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "protostar"
require_relative "../test/support/corpus"

def best(runs = 10)
  times = Array.new(runs) do
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end
  times.min * 1000
end

def best_inner(runs = 10)
  Array.new(runs) { yield }.min * 1000
end

def clock
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
end

def row(label, ms)
  puts format("%-62s %9.1f ms", label, ms)
end

C = Protostar::Compiler
NAME = "google/protobuf/unittest.proto"
ROOTS = Corpus::INCLUDE_ROOTS
source = File.read(File.join(ROOTS.first, NAME))
fresh = -> { C.new(include_paths: ROOTS) }

row "lex unittest.proto", best {
  lexer = C::Lexer.new(source, ->(*) {})
  lexer.next until lexer.current.type == :end
}
row "parse unittest.proto", best { C::Parser.new(source).parse(NAME) }

warm = fresh.call
warm.compile([NAME])
imports = warm.pool.file(NAME).dependency_files.map(&:name)
row "compile unittest.proto, imports pooled, builtin ready", best_inner {
  c = fresh.call
  c.compile(imports, retain_options: true)
  c.send(:builtin_options_type, "google.protobuf.FileOptions")
  clock { c.compile([NAME]) }
}
row "compile unittest.proto, fresh Compiler", best { fresh.call.compile([NAME]) }
row "  the same, retain_options: true", best { fresh.call.compile([NAME], retain_options: true) }
row "  the same, source_info: true", best { fresh.call.compile([NAME], source_info: true) }
row "compile descriptor.proto, fresh Compiler", best { fresh.call.compile(["google/protobuf/descriptor.proto"]) }

files = fresh.call.compile([NAME], source_info: true)
emitter = C::Emitters::Ruby.new
ruby = files.map { |f| emitter.file(f) }
row "emit native Ruby, unittest.proto and its 3 imports", best { files.each { |f| emitter.file(f) } }
module DSLBench
  class << self
    attr_accessor :pool
  end

  def self.file(*args, **kwargs, &block)
    Protostar::DSL.file(*args, **kwargs, pool: pool, registry: nil, &block)
  end
end
blocks = ruby.map { |src| src[/^Protostar::DSL\.file.*?^end$/m].sub("Protostar::DSL.file(", "DSLBench.file(") }
row "load that Ruby (the DSL) into a fresh pool", best {
  DSLBench.pool = Protostar::Schema::Pool.new
  blocks.each { |b| eval(b) } # standard:disable Security/Eval
}
bytes = files.map { |f| f.serialize(source_info: false) }
row "add_serialized_file, unittest.proto and its 3 imports", best {
  pool = Protostar::Schema::Pool.new
  bytes.each { |b| pool.add_serialized_file(b) }
}
row "to_proto of unittest.proto, with source info", best { files.last.to_proto }
row "serialize unittest.proto, with source info", best { files.last.serialize }
row "serialize unittest.proto, without source info", best { files.last.serialize(source_info: false) }

if ARGV.include?("corpus")
  protos = Corpus.protos.map do |path|
    root = ROOTS.find { |r| path.start_with?(r + "/") }
    path.delete_prefix(root + "/")
  end
  row "whole corpus, 107 files, fresh Compiler each", best(3) { protos.each { |n| fresh.call.compile([n]) } }
  row "  the same, source_info: true", best(3) { protos.each { |n| fresh.call.compile([n], source_info: true) } }
end
