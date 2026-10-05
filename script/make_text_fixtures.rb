# frozen_string_literal: true

# Bakes text format fixtures with protoc: for every corpus
# testdata/text_format_*.txt (and map_test_data.txt), plus the hand-written
# inputs under test/text/inputs, it writes into test/corpus/text_format/
#
#   <name>.binpb        what `protoc --encode` makes of the text
#   <name>.txt          what `protoc --decode` prints for those bytes
#   <name>.unknown.txt  the same bytes printed as proto2_unittest.TestEmptyMessage,
#                       which makes every field an unknown one
#   <name>.error.txt    protoc's complaint, instead of the above, when it rejects the text
#
#   ruby script/make_text_fixtures.rb
#
# Tests read the outputs; they never need protoc.

require "fileutils"
require "json"
require "open3"

REPO = File.expand_path("..", __dir__)
CORPUS = File.join(REPO, "test", "corpus", "protobuf")
OUT = File.join(REPO, "test", "corpus", "text_format")
INPUTS = File.join(REPO, "test", "text", "inputs")
PROTOC = ENV["PROTOC"] || File.expand_path("~/.cache/protostar/protoc-36.2/bin/protoc")
INCLUDE_ROOTS = %w[src . ruby/tests src/google/protobuf/compiler/ruby].map { |r| File.expand_path(r, CORPUS) }.freeze
UNITTEST = "google/protobuf/unittest.proto"
EMPTY = "proto2_unittest.TestEmptyMessage"

abort "No protoc at #{PROTOC}; run `rake protoc:install` or set PROTOC" unless File.executable?(PROTOC)

# [name, input path, proto, message]
def fixtures
  testdata = File.join(CORPUS, "src", "google", "protobuf", "testdata")
  list = Dir[File.join(testdata, "text_format_*.txt")].sort.map do |path|
    message = path.include?("extensions") ? "proto2_unittest.TestAllExtensions" : "proto2_unittest.TestAllTypes"
    [File.basename(path, ".txt"), path, UNITTEST, message]
  end
  list << ["map_test_data", File.join(testdata, "map_test_data.txt"), "google/protobuf/map_unittest.proto", "proto2_unittest.TestMap"]
  Dir[File.join(INPUTS, "*.txt")].sort.each do |path|
    header = File.read(path)
    proto = header[/^# proto: (\S+)/, 1] or abort "#{path} lacks a '# proto:' line"
    message = header[/^# message: (\S+)/, 1] or abort "#{path} lacks a '# message:' line"
    list << [File.basename(path, ".txt"), path, proto, message]
  end
  list
end

def protoc(mode, type, protos, input)
  includes = INCLUDE_ROOTS.flat_map { |r| ["-I", r] }
  out, err, status = Open3.capture3(PROTOC, *includes, "--#{mode}=#{type}", *protos.uniq, stdin_data: input, binmode: true)
  # protoc warns about generic services in unittest.proto on every run
  err = err.lines.reject { |l| l.include?("Generic services") }.join
  [status.success? ? out : nil, err]
end

FileUtils.rm_rf(OUT)
FileUtils.mkdir_p(OUT)
manifest = {}
fixtures.each do |name, path, proto, message|
  manifest[name] = {"proto" => proto, "message" => message}
  bytes, err = protoc("encode", message, [proto], File.binread(path))
  unless bytes
    File.write(File.join(OUT, "#{name}.error.txt"), err.gsub(REPO + "/", ""))
    puts "#{name}: rejected by protoc"
    next
  end
  File.binwrite(File.join(OUT, "#{name}.binpb"), bytes)
  text, err = protoc("decode", message, [proto, UNITTEST], bytes)
  abort "#{name}: protoc could not decode its own encoding:\n#{err}" unless text
  File.write(File.join(OUT, "#{name}.txt"), text)
  unknown, err = protoc("decode", EMPTY, [proto, UNITTEST], bytes)
  abort "#{name}: protoc could not decode as #{EMPTY}:\n#{err}" unless unknown
  File.write(File.join(OUT, "#{name}.unknown.txt"), unknown)
  puts "#{name}: #{bytes.bytesize} bytes"
end
File.write(File.join(OUT, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
version, = Open3.capture2(PROTOC, "--version")
File.write(File.join(OUT, "PROTOC"), version)
