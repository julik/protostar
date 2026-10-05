# frozen_string_literal: true

# Generates protostar's own `_pb.rb` files for descriptor.proto, plugin.proto
# and the well-known types into lib/protostar/google/protobuf/, from the
# bundled includes, with the native emitter. Constants live under
# Protostar::Google::Protobuf so they never meet google-protobuf's. Their RBS
# signatures go to sig/protostar/google/protobuf/.
#
#   ruby script/bootstrap.rb check       # fails on any difference
#   ruby script/bootstrap.rb regenerate  # rewrites the files
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "protostar"
require "fileutils"

module Bootstrap
  ROOT = File.expand_path("../lib/protostar", __dir__)
  SIG = File.expand_path("../sig/protostar", __dir__)
  Emitters = Protostar::Compiler::Emitters

  # @return [Hash{String => String}] path to source, Ruby under lib/protostar and RBS under sig/protostar
  def self.generate
    compiler = Protostar::Compiler.new(include_paths: [], bundled_includes: true)
    files = compiler.compile(Emitters::BOOTSTRAP, source_info: true)
    namespaces = files.to_h { |f| [f.name, "Protostar::#{Emitters::Naming.module_path(f).join("::")}"] }
    ruby = Emitters::Ruby.new(namespaces: namespaces)
    rbs = Emitters::ProtostarRbs.new(namespaces: namespaces)
    files.select { |f| Emitters::BOOTSTRAP.include?(f.name) }.each_with_object({}) do |f, out|
      base = Emitters::Naming.require_name(f.name)
      out[File.join(ROOT, base + ".rb")] = ruby.file(f)
      out[File.join(SIG, base + ".rbs")] = rbs.file(f)
    end
  end

  # @return [Array<String>] paths whose committed contents differ
  def self.differences
    generate.reject { |path, source| File.file?(path) && File.read(path) == source }.keys
  end

  def self.regenerate
    generate.each do |path, source|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV.first
  when "check"
    stale = Bootstrap.differences
    unless stale.empty?
      abort "Bootstrap files differ from what the compiler generates:\n  #{stale.join("\n  ")}\n" \
        "Run `rake bootstrap:regenerate`."
    end
    puts "Bootstrap files are up to date."
  when "regenerate"
    Bootstrap.regenerate
  else
    abort "usage: ruby script/bootstrap.rb check|regenerate"
  end
end
