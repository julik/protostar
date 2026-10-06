# frozen_string_literal: true

# The compiler numbers of docs/compiler-internals.md section 21: the stages
# on unittest.proto, a whole compile, descriptor.proto, and the whole corpus.
# Each row is the best of several runs. There is no google-protobuf side:
# its compiler is protoc, a separate program.
#
#   ruby bench/compiler_bench.rb
#   BENCH_CORPUS=0 ruby bench/compiler_bench.rb   # without the slow whole-corpus rows

require_relative "bench"
require_relative "fixtures"

Bench.section "Compiler" do |s|
  next if Bench.google?
  c = Protostar::Compiler
  name = "google/protobuf/unittest.proto"
  roots = Corpus::INCLUDE_ROOTS
  source = File.read(File.join(roots.first, name))
  fresh = -> { c.new(include_paths: roots) }

  s.slow("lex unittest.proto", runs: 10) do
    lexer = c::Lexer.new(source, ->(*) {})
    lexer.next until lexer.current.type == :end
  end
  s.slow("parse unittest.proto", runs: 10) { c::Parser.new(source).parse(name) }
  warm = fresh.call
  warm.compile([name])
  imports = warm.pool.file(name).dependency_files.map(&:name)
  prepare = lambda do
    compiler = fresh.call
    compiler.compile(imports, retain_options: true)
    compiler.send(:builtin_options_type, "google.protobuf.FileOptions")
    compiler
  end
  s.slow("compile unittest.proto, imports pooled, built-in descriptor.proto ready", runs: 10, prepare: prepare) do |compiler|
    compiler.compile([name])
  end
  s.slow("compile unittest.proto, fresh Compiler", runs: 10) { fresh.call.compile([name]) }
  s.slow("compile unittest.proto, retain_options: true", runs: 10) { fresh.call.compile([name], retain_options: true) }
  s.slow("compile unittest.proto, source_info: true", runs: 10) { fresh.call.compile([name], source_info: true) }
  s.slow("compile descriptor.proto, fresh Compiler", runs: 10) { fresh.call.compile(["google/protobuf/descriptor.proto"]) }

  files = fresh.call.compile([name], source_info: true)
  emitter = c::Emitters::Ruby.new
  s.slow("emit native Ruby, unittest.proto and 3 imports", runs: 10) { files.each { |f| emitter.file(f) } }
  s.slow("to_proto of unittest.proto, with source info", runs: 10) { files.last.to_proto }
  s.slow("serialize unittest.proto, with source info", runs: 10) { files.last.serialize }
  s.slow("serialize unittest.proto, without source info", runs: 10) { files.last.serialize(source_info: false) }

  if ENV["BENCH_CORPUS"] != "0"
    protos = Corpus.protos.map do |path|
      root = roots.find { |r| path.start_with?(r + "/") }
      path.delete_prefix(root + "/")
    end
    s.slow("whole corpus, #{protos.size} files, a fresh Compiler each", runs: 3) do
      protos.each { |n| fresh.call.compile([n]) }
    end
    s.slow("whole corpus, source_info: true", runs: 3) do
      protos.each { |n| fresh.call.compile([n], source_info: true) }
    end
  end
end
