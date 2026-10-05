# frozen_string_literal: true

# Records what the grpc-tools gem's Ruby plugin writes for the gRPC emitter's
# goldens: ruby/tests/service_test.proto from the corpus and the protos under
# test/corpus/generated/grpc/protos. grpc-tools is not in the Gemfile; install
# it anywhere and point GRPC_TOOLS at its grpc_tools_ruby_protoc:
#
#   GEM_HOME=/tmp/grpc-gems gem install grpc-tools
#   GRPC_TOOLS=/tmp/grpc-gems/bin/grpc_tools_ruby_protoc GEM_HOME=/tmp/grpc-gems \
#     ruby script/record_grpc_goldens.rb
require "fileutils"
require "tmpdir"

root = File.expand_path("..", __dir__)
tool = ENV.fetch("GRPC_TOOLS") { abort "set GRPC_TOOLS to grpc_tools_ruby_protoc" }
dir = File.join(root, "test/corpus/generated/grpc")
protos = File.join(dir, "protos")
out = File.join(dir, "out")
corpus_tests = File.join(root, "test/corpus/protobuf/ruby/tests")

FileUtils.rm_rf(out)
FileUtils.mkdir_p(out)
runs = [
  [corpus_tests, ["service_test.proto"]],
  [protos, Dir.chdir(protos) { Dir["**/*.proto"].sort }]
]
runs.each do |include_dir, files|
  Dir.mktmpdir do |tmp|
    ok = system(tool, "-I#{include_dir}", "-I#{protos}", "--grpc_out=#{tmp}", *files)
    abort "grpc_tools_ruby_protoc failed" unless ok
    Dir.chdir(tmp) do
      Dir["**/*_services_pb.rb"].each do |path|
        FileUtils.mkdir_p(File.join(out, File.dirname(path)))
        FileUtils.cp(path, File.join(out, path))
      end
    end
  end
end
version = `#{tool} --version`.strip
File.write(File.join(dir, "VERSION"), "grpc-tools #{ENV.fetch("GRPC_TOOLS_VERSION", "")}#{version}\n".squeeze(" "))
puts Dir.chdir(out) { Dir["**/*.rb"].sort }
