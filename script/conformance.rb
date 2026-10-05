# frozen_string_literal: true

# protobuf's conformance suite against protostar.
#
#   ruby script/conformance.rb build        # build conformance_test_runner from protobuf v36.2 (CMake, minutes)
#   ruby script/conformance.rb run          # run the binary, JSON and text-format suites against conformance/run_testee
#   ruby script/conformance.rb regenerate   # rewrite conformance/generated/*_pb.rb with exe/protostar compile
#   ruby script/conformance.rb check        # fail when conformance/generated/ is not what regenerate would write
#
# The runner lives in ~/.cache/protostar/conformance-36.2 (CONFORMANCE_HOME overrides it,
# CONFORMANCE_RUNNER points at a prebuilt binary). Extra arguments to `run` go to the
# runner, e.g. `--test Required.Proto3.JsonInput.Int32FieldMaxValue.ProtobufOutput`.

require "fileutils"
require "open3"
require "tmpdir"
require "etc"

PIN = "v36.2"
REPO = File.expand_path("..", __dir__)
CONFORMANCE = File.join(REPO, "conformance")
GENERATED = File.join(CONFORMANCE, "generated")
CORPUS = File.join(REPO, "test", "corpus", "protobuf")
HOME = ENV.fetch("CONFORMANCE_HOME", File.expand_path("~/.cache/protostar/conformance-#{PIN.delete_prefix("v")}"))
RUNNER = ENV.fetch("CONFORMANCE_RUNNER", File.join(HOME, "bin", "conformance_test_runner"))

# Kept in one place so CI can key its cache on them.
# jsoncpp is built as a shared library; the rpath lets the runner find it
# next to itself in bin/, which is all CI caches
CMAKE_FLAGS = %W[
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_CXX_STANDARD=17
  -Dprotobuf_BUILD_CONFORMANCE=ON
  -Dprotobuf_BUILD_TESTS=OFF
  -Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON
  -Dprotobuf_INSTALL=OFF
  -DCMAKE_BUILD_RPATH=#{/darwin/.match?(RUBY_PLATFORM) ? "@executable_path" : "$ORIGIN"}
].freeze

# The .proto files the runner sends messages of, with the include root each resolves under
PROTOS = [
  ["conformance/conformance.proto", CORPUS],
  ["google/protobuf/test_messages_proto2.proto", File.join(CORPUS, "src")],
  ["google/protobuf/test_messages_proto3.proto", File.join(CORPUS, "src")],
  ["conformance/test_protos/test_messages_edition2023.proto", CORPUS],
  ["conformance/test_protos/test_messages_edition_unstable.proto", CORPUS],
  ["editions/golden/test_messages_proto2_editions.proto", CORPUS],
  ["editions/golden/test_messages_proto3_editions.proto", CORPUS]
].freeze

def sh!(*cmd, **opts)
  puts "+ #{cmd.join(" ")}"
  system(*cmd, exception: true, **opts)
end

def cmake
  [ENV["CMAKE"], "cmake", File.expand_path("~/.cache/protostar/cmake-venv/bin/cmake")].compact.find do |c|
    c.include?("/") ? File.executable?(c) : system("which", c, out: File::NULL, err: File::NULL)
  end or abort "No cmake found. Install CMake 3.16 or newer, or set CMAKE"
end

def build
  src = File.join(HOME, "src")
  unless File.exist?(File.join(src, "CMakeLists.txt"))
    FileUtils.mkdir_p(src)
    tarball = File.join(HOME, "protobuf-#{PIN}.tar.gz")
    sh!("curl", "-sSfL", "-o", tarball, "https://github.com/protocolbuffers/protobuf/archive/refs/tags/#{PIN}.tar.gz")
    sh!("tar", "xzf", tarball, "-C", src, "--strip-components", "1")
  end
  build_dir = File.join(HOME, "build")
  generator = system("which", "ninja", out: File::NULL, err: File::NULL) ? ["-G", "Ninja"] : []
  sh!(cmake, "-S", src, "-B", build_dir, *generator, *CMAKE_FLAGS)
  sh!(cmake, "--build", build_dir, "--target", "conformance_test_runner", "--parallel", Etc.nprocessors.to_s)
  FileUtils.mkdir_p(File.dirname(RUNNER))
  FileUtils.cp(File.join(build_dir, "conformance_test_runner"), RUNNER)
  Dir.glob(File.join(build_dir, "_deps", "jsoncpp-build", "**", "libjsoncpp*.{so,dylib}*")).each do |lib|
    FileUtils.cp(lib, File.dirname(RUNNER))
  end
  puts "Runner at #{RUNNER}"
end

def run(extra)
  abort "No runner at #{RUNNER}. Run `rake conformance:build` first" unless File.executable?(RUNNER)
  output_dir = File.join(REPO, "tmp", "conformance")
  FileUtils.rm_rf(output_dir)
  FileUtils.mkdir_p(output_dir)
  sh!(RUNNER,
    "--enforce_recommended",
    "--maximum_edition", "2024",
    "--failure_list", File.join(CONFORMANCE, "failure_list_protostar.txt"),
    "--text_format_failure_list", File.join(CONFORMANCE, "text_format_failure_list_protostar.txt"),
    "--output_dir", output_dir,
    *extra,
    File.join(CONFORMANCE, "run_testee"))
end

# The files `protostar compile` writes for PROTOS, as {relative path => source}
def generate
  Dir.mktmpdir do |out|
    PROTOS.group_by(&:last).each do |root, protos|
      cmd = [RbConfig.ruby, File.join(REPO, "exe", "protostar"), "compile", "-I", root, "--ruby_out=#{out}", *protos.map(&:first)]
      _, err, status = Open3.capture3(*cmd)
      abort "#{cmd.join(" ")} failed:\n#{err}" unless status.success?
    end
    Dir.glob("**/*_pb.rb", base: out).sort.to_h { |rel| [rel, File.read(File.join(out, rel))] }
  end
end

def regenerate
  FileUtils.rm_rf(GENERATED)
  generate.each do |rel, source|
    path = File.join(GENERATED, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    puts "wrote #{path.delete_prefix(REPO + "/")}"
  end
end

def check
  expected = generate
  actual = Dir.glob("**/*_pb.rb", base: GENERATED).sort.to_h { |rel| [rel, File.read(File.join(GENERATED, rel))] }
  stale = (expected.keys | actual.keys).reject { |rel| expected[rel] == actual[rel] }
  abort "conformance/generated is stale (#{stale.join(", ")}). Run `rake conformance:regenerate`" unless stale.empty?
  puts "conformance/generated is current"
end

case ARGV.shift
when "build" then build
when "run" then run(ARGV)
when "regenerate" then regenerate
when "check" then check
when "cmake-flags" then puts CMAKE_FLAGS.join(" ")
else abort "usage: ruby script/conformance.rb build | run [runner args] | regenerate | check | cmake-flags"
end
