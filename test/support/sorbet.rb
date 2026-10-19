# frozen_string_literal: true

require "open3"

# Runs sorbet-static's `sorbet` when it is there: SORBET names the binary, or
# the bundle has the gem (BUNDLE_WITH=sorbet)
module SorbetSupport
  ROOT = File.expand_path("../..", __dir__)
  RUNTIME_RBI = File.join(ROOT, "rbi")
  GOOGLE_STUB = File.join(ROOT, "test/fixtures/sorbet/google_protobuf.rbi")

  module_function

  # @return [String, nil]
  def executable
    return ENV["SORBET"] if ENV["SORBET"] && File.executable?(ENV["SORBET"])
    spec = Gem::Specification.find_by_name("sorbet-static")
    path = File.join(spec.full_gem_path, "libexec", "sorbet")
    path if File.executable?(path)
  rescue Gem::MissingSpecError
    nil
  end

  # @return [Array(String, Boolean)] what sorbet printed, and whether it found no errors
  def typecheck(*paths)
    out, err, status = Open3.capture3(executable, "--no-config", "--no-error-count", *paths)
    [out + err, status.success?]
  end
end
