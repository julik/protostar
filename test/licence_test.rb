# frozen_string_literal: true

require "test_helper"

# Both gems ship their licence and the notices for what they carry of Google's
class LicenceTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SHIM = File.join(ROOT, "shims/google-protobuf")

  def files(dir, gemspec)
    Dir.chdir(dir) { Gem::Specification.load(gemspec).files }
  end

  def test_protostar_gem
    files = files(ROOT, "protostar.gemspec")
    %w[LICENSE.txt THIRD_PARTY_NOTICES.md lib/protostar/compiler/include/LICENSE].each do |f|
      assert_includes files, f
    end
    notices = File.read(File.join(ROOT, "THIRD_PARTY_NOTICES.md"))
    assert_includes notices, File.read(File.join(ROOT, "lib/protostar/compiler/include/LICENSE"))
    %w[lib/protostar/compiler/include/ test/corpus/ lib/protostar/google/protobuf/ shims/google-protobuf/lib/].each { |p| assert_includes notices, p }
    assert_includes File.read(File.join(ROOT, "README.md")), "THIRD_PARTY_NOTICES.md"
  end

  def test_shim_gem
    files = files(SHIM, "google-protobuf.gemspec")
    %w[LICENSE.txt THIRD_PARTY_NOTICES.md].each { |f| assert_includes files, f }
    assert_match(/MIT License/, File.read(File.join(SHIM, "LICENSE.txt")))
    notices = File.read(File.join(SHIM, "THIRD_PARTY_NOTICES.md"))
    assert_includes notices, File.read(File.join(ROOT, "test/corpus/protobuf/LICENSE"))
    %w[lib/google/protobuf/*_pb.rb test/google/].each { |p| assert_includes notices, p }
    assert_includes File.read(File.join(SHIM, "README.md")), "THIRD_PARTY_NOTICES.md"
  end
end
