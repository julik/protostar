# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "fileutils"

# The gems as a user gets them: both built from their gemspecs, installed
# into an empty GEM_HOME, and used from a subprocess with no Bundler, no
# -I and nothing from this checkout on the load path. The only test that
# touches installed gems.
class ReleaseTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SHIM = File.join(ROOT, "shims", "google-protobuf")

  PROTO = <<~PROTO
    syntax = "proto3";
    package release;
    import "google/protobuf/timestamp.proto";
    message Note {
      string text = 1;
      repeated int32 marks = 2;
      map<string, string> tags = 3;
      google.protobuf.Timestamp at = 4;
    }
  PROTO

  def self.installed
    @installed ||= begin
      dir = File.realpath(TestSupport.tmpdir("protostar-release"))
      gem_home = File.join(dir, "gem_home")
      gems = [[ROOT, "protostar.gemspec"], [SHIM, "google-protobuf.gemspec"]].map do |source, gemspec|
        target = File.join(dir, gemspec.sub(".gemspec", ".gem"))
        run!(clean_env, RbConfig.ruby, "-S", "gem", "build", gemspec, "-o", target, chdir: source)
        target
      end
      run!(clean_env, RbConfig.ruby, "-S", "gem", "install", "--local", "--no-document", "--install-dir", gem_home, *gems,
        chdir: dir)
      [dir, gem_home]
    end
  end

  # The environment of a shell with nothing of this checkout's bundle in it
  def self.clean_env(gem_home = nil)
    env = ENV.to_h.reject do |k, _|
      k.start_with?("BUNDLE_", "BUNDLER_") || %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH PROTOSTAR_ORACLE].include?(k)
    end
    gem_home ? env.merge("GEM_HOME" => gem_home, "GEM_PATH" => gem_home) : env
  end

  def self.run!(env, *command, chdir:)
    out, status = Open3.capture2e(env, *command, chdir: chdir, unsetenv_others: true)
    raise "#{command.join(" ")} failed:\n#{out}" unless status.success?
    out
  end

  def setup
    @dir, @gem_home = self.class.installed
    @work = tmpdir("work")
    File.write(File.join(@work, "note.proto"), PROTO)
  end

  def sh(*command)
    self.class.run!(self.class.clean_env(@gem_home), *command, chdir: @work)
  end

  def ruby(source)
    sh(RbConfig.ruby, "-e", source)
  end

  def test_both_gems_are_installed_at_the_same_version
    specs = Dir[File.join(@gem_home, "specifications", "*.gemspec")].map { |f| File.basename(f, ".gemspec") }.sort
    assert_equal ["google-protobuf-#{shim_version}", "protostar-#{Protostar::VERSION}"], specs
    dependency = ruby(<<~RUBY)
      spec = Gem::Specification.find_by_name("google-protobuf")
      print spec.runtime_dependencies.map(&:to_s).join(",")
    RUBY
    assert_equal "protostar (= #{Protostar::VERSION})", dependency
  end

  def test_compile_with_the_installed_cli_and_round_trip
    assert_equal "protostar #{Protostar::VERSION}\n", sh(File.join(@gem_home, "bin", "protostar"), "--version")
    sh(File.join(@gem_home, "bin", "protostar"), "compile", "-I", ".", "--ruby_out=.", "note.proto")
    assert File.exist?(File.join(@work, "note_pb.rb"))
    out = ruby(<<~RUBY)
      $LOAD_PATH.unshift(Dir.pwd)
      require "note_pb"
      note = Release::Note.new(text: "hi", marks: [1, 2], tags: {"a" => "b"}, at: Time.at(1_700_000_000))
      copy = Release::Note.decode(note.encode)
      raise "round trip" unless copy == note
      raise "json" unless Release::Note.decode_json(note.to_json) == note
      puts copy.inspect
      puts Gem.loaded_specs.fetch("protostar").full_gem_path
      puts $LOADED_FEATURES.grep(%r{/protostar\\.rb\\z}).join(",")
      puts defined?(Bundler).inspect
    RUBY
    inspect, gem_path, feature, bundler = out.lines.map(&:chomp)
    assert_equal '#<release.Note text: "hi", marks: [1, 2], tags: {"a" => "b"}, at: #<google.protobuf.Timestamp seconds: 1700000000>>',
      inspect.gsub(/"(\w+)"=>/, '"\1" => ') # Hash#inspect before Ruby 3.4
    assert_equal File.join(@gem_home, "gems", "protostar-#{Protostar::VERSION}"), gem_path
    assert feature.start_with?(@gem_home), "protostar.rb loaded from #{feature}"
    assert_equal "nil", bundler
  end

  def test_the_shim_loads_a_google_format_file
    sh(File.join(@gem_home, "bin", "protostar"), "compile", "-I", ".", "--google_out=.", "note.proto")
    assert_includes File.read(File.join(@work, "note_pb.rb")), "add_serialized_file"
    out = ruby(<<~RUBY)
      $LOAD_PATH.unshift(Dir.pwd)
      require "google/protobuf"
      require "note_pb"
      note = Release::Note.new(text: "hi", marks: [1, 2], tags: {"a" => "b"},
        at: Google::Protobuf::Timestamp.new(seconds: 1_700_000_000))
      copy = Release::Note.decode(Release::Note.encode(note))
      raise "round trip" unless copy == note
      puts Google::Protobuf::IMPLEMENTATION
      puts Gem.loaded_specs.fetch("google-protobuf").version
      puts Release::Note.encode_json(copy)
      puts copy.marks.class
    RUBY
    assert_equal ["PROTOSTAR", shim_version, '{"text":"hi","marks":[1,2],"tags":{"a":"b"},"at":"2023-11-14T22:13:20Z"}',
      "Google::Protobuf::RepeatedField"], out.lines.map(&:chomp)
  end

  # The shim gem is installed here too, so this proves the copy inside protostar is the one used
  def test_the_shim_bundled_in_protostar_loads_a_google_format_file
    sh(File.join(@gem_home, "bin", "protostar"), "compile", "-I", ".", "--google_out=.", "note.proto")
    out = ruby(<<~RUBY)
      $LOAD_PATH.unshift(Dir.pwd)
      require "protostar/google_protobuf_shim"
      require "note_pb"
      note = Release::Note.new(text: "hi", marks: [1, 2])
      raise "round trip" unless Release::Note.decode(Release::Note.encode(note)) == note
      puts Google::Protobuf::IMPLEMENTATION
      puts $LOADED_FEATURES.grep(%r{/google/protobuf\\.rb\\z})
      puts Gem.loaded_specs.key?("google-protobuf")
    RUBY
    shim = File.join(@gem_home, "gems", "protostar-#{Protostar::VERSION}", "shims", "google-protobuf", "lib", "google", "protobuf.rb")
    assert_equal ["PROTOSTAR", shim, "false"], out.lines.map(&:chomp)
  end

  def test_the_protoc_plugin_is_installed
    plugin = File.join(@gem_home, "bin", "protoc-gen-protostar")
    assert File.executable?(plugin)
    # an empty CodeGeneratorRequest gets a response naming the supported features
    response = sh(RbConfig.ruby, "-e", <<~RUBY)
      require "open3"
      out, status = Open3.capture2(#{plugin.inspect}, stdin_data: "", binmode: true)
      raise "plugin failed" unless status.success?
      require "protostar"
      require "protostar/google/protobuf/compiler/plugin_pb"
      print Protostar::Google::Protobuf::Compiler::CodeGeneratorResponse.decode(out).supported_features
    RUBY
    assert_operator response.to_i, :>, 0
  end

  def shim_version
    File.read(File.join(SHIM, "google-protobuf.gemspec"))[/spec\.version = "([^"]+)"/, 1]
  end
end
