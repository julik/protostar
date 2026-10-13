# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"

# `require "protostar"` loads the schema, the wire format and the codec;
# everything else is autoloaded. Both tests start a Ruby of their own, since
# the test process has loaded most of protostar already.
class AutoloadTest < Minitest::Test
  LIB = File.join(TestSupport::ROOT, "lib")

  # Parts a bare require must leave alone, relative to lib/
  OPTIONAL = %r{\Aprotostar/(?:compiler|json|text|view|builder|well_known|google|short_names)(?:/|\.rb\z)|
    \Aprotostar/(?:dsl|types|cli|plugin|google_protobuf_shim)\.rb\z|\Aprotostar/schema/(?:proto|draft)(?:/|\.rb\z)}x

  def run_ruby(script)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", script)
    assert status.success?, err
    JSON.parse(out)
  end

  def test_require_loads_none_of_the_optional_parts
    loaded = run_ruby(<<~RUBY)
      require "json"
      before = $LOADED_FEATURES.dup
      require "protostar"
      lib = #{"#{LIB}/".inspect}
      puts JSON.generate(($LOADED_FEATURES - before).select { |f| f.start_with?(lib) }.map { |f| f.delete_prefix(lib) })
    RUBY
    assert_includes loaded, "protostar/codec/decoder.rb"
    assert_empty loaded.grep(OPTIONAL)
  end

  # Every autoload declared under Protostar resolves to what its file
  # defines, and between them they load every Ruby file in lib/, so a new
  # file cannot be left out
  def test_every_autoload_resolves
    result = run_ruby(<<~RUBY)
      require "json"
      DECLARED = []
      Module.prepend(Module.new do
        def autoload(name, path)
          DECLARED << [self, name, path]
          super
        end
      end)
      require "protostar"
      resolved = []
      missing = []
      # Resolving one loads files that declare more, so the list grows as it is walked
      DECLARED.each do |mod, name, path|
        value = mod.const_get(name, false)
        missing << "\#{mod}::\#{name}" unless $LOADED_FEATURES.include?("\#{path}.rb") && value
        resolved << "\#{mod}::\#{name}"
      end
      lib = #{"#{LIB}/".inspect}
      loaded = $LOADED_FEATURES.select { |f| f.start_with?(lib) }.map { |f| f.delete_prefix(lib) }
      puts JSON.generate(resolved: resolved, missing: missing, loaded: loaded)
    RUBY
    assert_empty result["missing"], "autoloads whose file was not loaded"
    %w[
      Protostar::Compiler Protostar::Compiler::Parser Protostar::Compiler::Emitters::Ruby Protostar::JSON
      Protostar::Text Protostar::View Protostar::Builder Protostar::WellKnown Protostar::Schema::Proto
      Protostar::Codec::DecodeGenerator Protostar::Google::Protobuf::FileDescriptorProto Protostar::Timestamp
    ].each { |name| assert_includes result["resolved"], name }
    # The shim swaps out google/protobuf for the whole process, so only a require may load it
    files = Dir.glob("**/*.rb", base: LIB) - ["protostar/google_protobuf_shim.rb"]
    assert_empty files - result["loaded"], "files no autoload reaches"
  end
end
