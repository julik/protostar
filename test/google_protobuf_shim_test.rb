# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# Each test starts a Ruby of its own, since loading the shim takes over google/protobuf
# for the whole process
class GoogleProtobufShimTest < Minitest::Test
  LIB = File.join(TestSupport::ROOT, "lib")
  SHIM_LIB = File.join(TestSupport::ROOT, "shims", "google-protobuf", "lib")

  def run_ruby(script, *load_path)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, *load_path.flat_map { |d| ["-I", d] }, "-e", script)
    [out, err, status]
  end

  def assert_ruby(script, *load_path)
    out, err, status = run_ruby(script, *load_path)
    assert status.success?, err
    out
  end

  def test_protostar_alone_leaves_google_protobuf_alone
    out = assert_ruby(<<~RUBY)
      require "protostar"
      Protostar::Timestamp
      print defined?(::Google::Protobuf).inspect
    RUBY
    assert_equal "nil", out
  end

  def test_require_loads_the_bundled_shim
    out = assert_ruby(<<~RUBY)
      require "protostar/google_protobuf_shim"
      require "google/protobuf/timestamp_pb"
      puts Google::Protobuf::IMPLEMENTATION
      puts Google::Protobuf::Timestamp.new(seconds: 1).to_json
      puts $LOADED_FEATURES.grep(%r{/google/protobuf\\.rb\\z})
    RUBY
    assert_equal ["PROTOSTAR", '"1970-01-01T00:00:01Z"', File.join(SHIM_LIB, "google/protobuf.rb")], out.lines.map(&:chomp)
  end

  # Bundler puts Google's gem on the load path when grpc depends on it
  def test_the_shim_wins_over_google_protobuf_on_the_load_path
    impostor = tmpdir("impostor")
    FileUtils.mkdir_p(File.join(impostor, "google/protobuf"))
    %w[google/protobuf.rb google/protobuf/timestamp_pb.rb].each do |f|
      File.write(File.join(impostor, f), "raise 'loaded Google\\'s #{f}'")
    end
    out = assert_ruby(<<~RUBY, impostor)
      require "protostar/google_protobuf_shim"
      require "google/protobuf/timestamp_pb"
      print Google::Protobuf::IMPLEMENTATION
    RUBY
    assert_equal "PROTOSTAR", out
  end

  def test_requiring_twice_is_harmless
    out = assert_ruby(<<~RUBY, SHIM_LIB)
      require "google/protobuf"
      load "protostar/google_protobuf_shim.rb"
      print $LOAD_PATH.count(#{SHIM_LIB.inspect})
    RUBY
    assert_equal "1", out
  end

  def test_refuses_when_google_protobuf_is_already_loaded
    _, err, status = run_ruby(<<~RUBY)
      module Google
        module Protobuf
          class DescriptorPool; end
          IMPLEMENTATION = :NATIVE
        end
      end
      require "protostar/google_protobuf_shim"
    RUBY
    refute status.success?
    assert_includes err, "Google's google-protobuf is already loaded"
  end
end
