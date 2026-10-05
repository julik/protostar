# frozen_string_literal: true

# Writes the shim's generated files with protostar's own compiler:
#
#   lib/google/protobuf/*_pb.rb          the well-known types, Google format
#   test/google/*_pb.rb                  Google's ruby/tests protos, Google format
#   test/grpc/generated/*_pb.rb          the gRPC test service, Google format and stubs
#   test/pbbuilder/generated/*_pb.rb     the messages the pbbuilder API test builds
#
#   ruby script/generate.rb          # write them
#   ruby script/generate.rb check    # fail when a committed file differs

require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.expand_path("../../lib", ROOT))
require "protostar"
require "protostar/cli"

CORPUS = File.expand_path("../../test/corpus/protobuf/ruby/tests", ROOT)

WELL_KNOWN = %w[any api duration empty field_mask source_context struct timestamp type wrappers descriptor]
  .map { |n| "google/protobuf/#{n}.proto" } + ["google/protobuf/compiler/plugin.proto"]

GOOGLE_TESTS = %w[
  basic_test basic_test_features basic_test_proto2 generated_code generated_code_editions
  generated_code_proto2 multi_level_nesting_test repeated_field_test service_test test_import
  test_import_proto2 test_ruby_package test_ruby_package_proto2 utf8
].map { |n| "#{n}.proto" }

JOBS = [
  {out: "lib", args: ["--google_out=%s", *WELL_KNOWN]},
  {out: "test/google", args: ["-I", CORPUS, "--google_out=%s", *GOOGLE_TESTS]},
  {out: "test/grpc/generated", args: ["-I", File.join(ROOT, "test/grpc"), "--google_out=%s", "--grpc_out=%s", "echo.proto"]},
  {out: "test/pbbuilder/generated", args: ["-I", File.join(ROOT, "test/pbbuilder"), "--google_out=%s", "person.proto"]}
].freeze

def generate(dir)
  JOBS.each do |job|
    out = File.join(dir, job[:out])
    FileUtils.mkdir_p(out)
    args = job[:args].map { |a| a.include?("%s") ? format(a, out) : a }
    status = Protostar::CLI.run(["compile", *args])
    abort "protostar compile #{args.join(" ")} failed" unless status.zero?
  end
end

def files(dir)
  JOBS.flat_map { |job| Dir.glob("**/*_pb.rb", base: File.join(dir, job[:out])).map { |f| File.join(job[:out], f) } }.sort
end

case ARGV.first
when nil
  generate(ROOT)
  puts files(ROOT)
when "check"
  Dir.mktmpdir do |tmp|
    generate(tmp)
    stale = files(tmp).reject { |f| File.exist?(File.join(ROOT, f)) && File.read(File.join(ROOT, f)) == File.read(File.join(tmp, f)) }
    abort "out of date: #{stale.join(", ")}; run ruby script/generate.rb" unless stale.empty?
    puts "#{files(tmp).size} generated files up to date"
  end
else
  abort "usage: ruby script/generate.rb [check]"
end
