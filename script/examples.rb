# frozen_string_literal: true

# The generated code committed under examples/.
#
#   ruby script/examples.rb regenerate   # rewrite every examples/**/*_pb.rb with exe/protostar compile
#   ruby script/examples.rb check        # fail when a committed *_pb.rb is not what regenerate would write
#
# Every directory holding .proto files is compiled with itself as the include
# path, as each playbook's README tells the reader to do.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

REPO = File.expand_path("..", __dir__)
EXAMPLES = File.join(REPO, "examples")

# {path relative to examples/ => source} for every _pb.rb `protostar compile` writes
def generate
  Dir.glob("**/*.proto", base: EXAMPLES).group_by { |rel| File.dirname(rel) }.sort.each_with_object({}) do |(dir, protos), out|
    Dir.mktmpdir do |tmp|
      cmd = [RbConfig.ruby, File.join(REPO, "exe", "protostar"), "compile", "-I", ".", "--ruby_out=#{tmp}",
        *protos.map { |p| File.basename(p) }.sort]
      _, err, status = Open3.capture3(*cmd, chdir: File.join(EXAMPLES, dir))
      abort "#{cmd.join(" ")} failed in examples/#{dir}:\n#{err}" unless status.success?
      Dir.glob("*_pb.rb", base: tmp).sort.each do |name|
        out[File.join(dir, name)] = File.read(File.join(tmp, name))
      end
    end
  end
end

def committed
  Dir.glob("**/*_pb.rb", base: EXAMPLES).sort.to_h { |rel| [rel, File.read(File.join(EXAMPLES, rel))] }
end

def regenerate
  generated = generate
  (committed.keys - generated.keys).each { |rel| FileUtils.rm(File.join(EXAMPLES, rel)) }
  generated.each do |rel, source|
    File.write(File.join(EXAMPLES, rel), source)
    puts "wrote examples/#{rel}"
  end
end

def check
  expected = generate
  actual = committed
  stale = (expected.keys | actual.keys).reject { |rel| expected[rel] == actual[rel] }
  abort "examples are stale (#{stale.join(", ")}). Run `rake examples:regenerate`" unless stale.empty?
  puts "examples are current"
end

case ARGV.shift
when "regenerate" then regenerate
when "check" then check
else abort "usage: ruby script/examples.rb regenerate | check"
end
