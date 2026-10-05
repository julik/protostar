# frozen_string_literal: true

# Vendors the protobuf test corpus and bakes protoc goldens for it.
#
#   ruby script/corpus.rb protoc    # download the pinned protoc into ~/.cache/protostar
#   ruby script/corpus.rb fetch     # sparse-clone protobuf at PIN and copy the corpus in
#   ruby script/corpus.rb goldens   # run protoc over every corpus .proto, write goldens
#
# Goldens need the google-protobuf gem for the JSON renditions, which is why
# this is a script and not part of the test suite.

require "fileutils"
require "open3"
require "tmpdir"
require "rbconfig"

PIN = "v36.2"
PROTOC_VERSION = "36.2"
REPO = File.expand_path("..", __dir__)
CORPUS = File.join(REPO, "test", "corpus", "protobuf")
GOLDENS = File.join(REPO, "test", "corpus", "goldens")
SRC = ENV.fetch("PROTOBUF_SRC", File.join(REPO, "tmp", "protobuf-src"))
PROTOC_HOME = File.expand_path("~/.cache/protostar/protoc-#{PROTOC_VERSION}")

# Everything we steal, as globs relative to the protobuf repo root
CORPUS_GLOBS = %w[
  LICENSE
  src/google/protobuf/*.proto
  src/google/protobuf/compiler/plugin.proto
  src/google/protobuf/compiler/ruby/*.proto
  src/google/protobuf/compiler/ruby/*_pb.rb
  src/google/protobuf/compiler/ruby/*.rbs
  src/google/protobuf/compiler/parser_unittest.cc
  src/google/protobuf/descriptor_unittest.cc
  src/google/protobuf/testdata/*.txt
  src/google/protobuf/testdata/bad_utf8_string
  conformance/*.proto
  conformance/test_protos/*.proto
  conformance/failure_list_ruby.txt
  conformance/text_format_failure_list_*.txt
  editions/golden/*.proto
  ruby/tests/*.proto
  ruby/tests/*.rb
].freeze

# Include roots handed to protoc, in order. Paths are relative to CORPUS
INCLUDE_ROOTS = %w[src . ruby/tests src/google/protobuf/compiler/ruby].freeze

def sh!(*cmd, chdir: nil)
  out, err, status = Open3.capture3(*cmd, chdir: chdir || Dir.pwd)
  abort "#{cmd.join(" ")} failed:\n#{err}" unless status.success?
  out
end

def protoc_binary
  candidates = [ENV["PROTOC"], File.join(PROTOC_HOME, "bin", "protoc")].compact
  found = candidates.find { |c| File.executable?(c) }
  found ||= begin
    sh!("which", "protoc").strip
  rescue
    nil
  end
  abort "No protoc found. Run `rake protoc:install` or set PROTOC" unless found
  version = sh!(found, "--version").strip
  warn "WARNING: #{found} is #{version}, goldens are pinned to #{PROTOC_VERSION}" unless version.end_with?(PROTOC_VERSION)
  found
end

def install_protoc
  platform = case RbConfig::CONFIG["host_os"]
  when /darwin/ then /arm|aarch/.match?(RbConfig::CONFIG["host_cpu"]) ? "osx-aarch_64" : "osx-x86_64"
  when /linux/ then /arm|aarch/.match?(RbConfig::CONFIG["host_cpu"]) ? "linux-aarch_64" : "linux-x86_64"
  else abort "Don't know which protoc to fetch for #{RbConfig::CONFIG["host_os"]}"
  end
  zip = "protoc-#{PROTOC_VERSION}-#{platform}.zip"
  url = "https://github.com/protocolbuffers/protobuf/releases/download/#{PIN}/#{zip}"
  FileUtils.mkdir_p(PROTOC_HOME)
  Dir.mktmpdir do |dir|
    sh!("curl", "-sSL", "-o", File.join(dir, zip), url)
    sh!("unzip", "-oq", File.join(dir, zip), "-d", PROTOC_HOME)
  end
  puts sh!(File.join(PROTOC_HOME, "bin", "protoc"), "--version")
end

def fetch
  unless File.directory?(File.join(SRC, ".git"))
    FileUtils.mkdir_p(File.dirname(SRC))
    sh!("git", "clone", "-q", "--depth", "1", "--branch", PIN, "--filter=blob:none", "--sparse",
      "https://github.com/protocolbuffers/protobuf.git", SRC)
    sh!("git", "sparse-checkout", "set", "src/google/protobuf", "conformance", "editions", "ruby/tests", chdir: SRC)
    sh!("git", "checkout", "-q", "HEAD", "--", ".", chdir: SRC)
  end
  commit = sh!("git", "rev-parse", "HEAD", chdir: SRC).strip

  FileUtils.rm_rf(CORPUS)
  copied = CORPUS_GLOBS.flat_map { |glob| Dir[File.join(SRC, glob)] }.sort.uniq
  copied.each do |abs|
    rel = abs.delete_prefix(SRC + "/")
    dest = File.join(CORPUS, rel)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(abs, dest)
  end
  File.write(File.join(CORPUS, "PIN"), "#{PIN} #{commit}\n")
  puts "copied #{copied.size} files from protobuf #{PIN} (#{commit[0, 12]})"
end

# A proto's path relative to the include root it will be resolved under, so
# that imports between corpus files line up the way protoc expects
def relative_to_root(abs)
  INCLUDE_ROOTS.each do |root|
    prefix = File.expand_path(root, CORPUS) + "/"
    return abs.delete_prefix(prefix) if abs.start_with?(prefix) && (root != "." || !abs.start_with?(File.join(CORPUS, "src/")))
  end
  raise "#{abs} is under no include root"
end

def goldens
  require "google/protobuf"
  require "google/protobuf/descriptor_pb"
  protoc = protoc_binary
  FileUtils.rm_rf(GOLDENS)
  ok = failed = 0
  Dir[File.join(CORPUS, "**", "*.proto")].sort.each do |abs|
    rel = relative_to_root(abs)
    target = File.join(GOLDENS, rel)
    FileUtils.mkdir_p(File.dirname(target))
    Dir.mktmpdir do |dir|
      out = File.join(dir, "set.binpb")
      includes = INCLUDE_ROOTS.flat_map { |r| ["-I", File.expand_path(r, CORPUS)] }
      _, err, status = Open3.capture3(protoc, *includes, "--include_imports", "--include_source_info",
        "--descriptor_set_out=#{out}", rel, chdir: CORPUS)
      if status.success?
        bin = File.binread(out)
        File.binwrite("#{target}.binpb", bin)
        # The JSON rendition drops source info to stay reviewable - spans and comments
        # are compared from the .binpb once our own codec can read it
        set = Google::Protobuf::FileDescriptorSet.decode(bin)
        set.file.each { |f| f.clear_source_code_info }
        File.write("#{target}.json", Google::Protobuf::FileDescriptorSet.encode_json(set))
        ok += 1
      else
        File.write("#{target}.error.txt", err.gsub(CORPUS + "/", ""))
        failed += 1
      end
    end
  end
  puts "goldens: #{ok} compiled, #{failed} rejected by protoc (see *.error.txt)"
end

case ARGV.first
when "protoc" then install_protoc
when "fetch" then fetch
when "goldens" then goldens
else abort "usage: ruby script/corpus.rb protoc|fetch|goldens"
end
