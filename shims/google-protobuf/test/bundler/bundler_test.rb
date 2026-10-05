# frozen_string_literal: true

require "test/unit"
require "tmpdir"
require "open3"
require "bundler"

# Resolves Gemfiles that depend on grpc (and so on google-protobuf) with this
# gem standing in, in a throwaway directory, and checks that Google's gem is
# nowhere in the lockfile
class BundlerTest < Test::Unit::TestCase
  SHIM = File.expand_path("../..", __dir__)
  ROOT = File.expand_path("../..", SHIM)

  def test_path_source
    lock = resolve(<<~GEMFILE)
      source "https://rubygems.org"
      gem "grpc"
      gem "googleapis-common-protos-types"
      gem "google-protobuf", path: #{SHIM.inspect}
      gem "protostar", path: #{ROOT.inspect}
    GEMFILE
    assert_shim_locked(lock, "PATH")
  end

  def test_git_source_with_glob
    omit "the repository is not a git checkout" unless File.exist?(File.join(ROOT, ".git"))
    revision = git("rev-parse", "HEAD")
    lock = resolve(<<~GEMFILE)
      source "https://rubygems.org"
      gem "grpc"
      git #{"file://#{ROOT}".inspect}, ref: #{revision.inspect}, glob: "{,shims/*/}*.gemspec" do
        gem "protostar"
        gem "google-protobuf"
      end
    GEMFILE
    assert_shim_locked(lock, "GIT")
  end

  # The README's `github:` form, with the repository given as a local git URL
  def test_git_sources_per_gem
    omit "the repository is not a git checkout" unless File.exist?(File.join(ROOT, ".git"))
    revision = git("rev-parse", "HEAD")
    url = "file://#{ROOT}"
    lock = resolve(<<~GEMFILE)
      source "https://rubygems.org"
      gem "grpc"
      gem "protostar", git: #{url.inspect}, ref: #{revision.inspect}
      gem "google-protobuf", git: #{url.inspect}, ref: #{revision.inspect}, glob: "shims/google-protobuf/*.gemspec"
    GEMFILE
    assert_shim_locked(lock, "GIT")
  end

  private

  def assert_shim_locked(lock, section)
    specs = Hash.new { |h, k| h[k] = +"" }
    lock.split(/^(?=[A-Z]+\n)/).each { |block| specs[block[/\A[A-Z]+/]] << block }
    assert_match(/^    google-protobuf \(4\.36\.2\.1\)$/, specs.fetch(section), "google-protobuf comes from the #{section} source")
    assert_no_match(/^    google-protobuf \(/, specs.fetch("GEM", ""), "no google-protobuf from rubygems.org")
    assert_match(/^    grpc \(/, specs.fetch("GEM"))
    assert_match(/^  google-protobuf!$/, specs.fetch("DEPENDENCIES"))
  end

  # Locks the Gemfile with gems already installed when it can, and from
  # rubygems.org when it cannot
  def resolve(gemfile)
    Dir.mktmpdir("protostar-shim-bundler") do |dir|
      File.write(File.join(dir, "Gemfile"), gemfile)
      output = nil
      Bundler.with_unbundled_env do
        env = {"BUNDLE_GEMFILE" => File.join(dir, "Gemfile"), "BUNDLE_APP_CONFIG" => File.join(dir, ".bundle")}
        ok = false
        [%w[bundle lock --local], %w[bundle lock]].each do |command|
          output, status = Open3.capture2e(env, *command, chdir: dir)
          ok = status.success?
          break if ok
        end
        assert ok, "bundle lock failed:\n#{output}"
      end
      File.read(File.join(dir, "Gemfile.lock"))
    end
  end

  def git(*args)
    out, status = Open3.capture2("git", *args, chdir: ROOT)
    assert status.success?
    out.strip
  end
end
