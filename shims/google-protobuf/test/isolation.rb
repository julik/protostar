# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The rules that let the shim's tests run in test-unit's process workers, as
# the root suite's test/support/test_support.rb has them: temp dirs are made
# here, under the repository's tmp/test/<pid>/, and ports are asked of the OS
# ("127.0.0.1:0"). test/shim/isolation_test.rb greps for anything else.
module Isolation
  ROOT = File.expand_path("../../..", __dir__)

  # A fresh directory, removed when the block returns
  def self.tmpdir(prefix = "t")
    root = File.join(ROOT, "tmp", "test", Process.pid.to_s)
    FileUtils.mkdir_p(root)
    dir = Dir.mktmpdir(prefix, root)
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
