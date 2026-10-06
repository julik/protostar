# frozen_string_literal: true

require "fileutils"
require "socket"
require "tmpdir"

# The isolation rules that let test files run in parallel processes. Each
# rule has a guard, so a new test cannot break one by accident:
#
# - temp dirs come from {TestSupport#tmpdir}, under tmp/test/<pid>/
#   (isolation_test.rb greps test/ for any other way to make one);
# - files are defined into a registry and pool of the test's own; one left
#   behind in the process-wide ones fails the test that put it there;
# - ENV is read once, at boot ({TestSupport::ORACLE});
# - ports come from {TestSupport.free_port};
# - nothing under test/corpus/ changes during a run ({TestSupport.watch_corpus}).
module TestSupport
  ROOT = File.expand_path("../..", __dir__)
  CORPUS = File.join(ROOT, "test", "corpus")

  # PROTOSTAR_ORACLE, read once: tests never toggle it
  ORACLE = ENV["PROTOSTAR_ORACLE"] ? true : false

  # What the generated `_pb.rb` files of lib/ may put into the process-wide
  # pool and registry, on first use
  GLOBAL_FILES = Protostar::Compiler::Emitters::BOOTSTRAP.to_set.freeze

  class << self
    # The directory every temp dir of this process goes under. Read per
    # call, because a forked worker has a pid of its own
    def tmp_root
      File.join(ROOT, "tmp", "test", Process.pid.to_s)
    end

    # A fresh directory under {tmp_root}. With a block it is removed when the
    # block returns; without one, when the process ends
    def tmpdir(prefix = "t")
      root = tmp_root
      unless @cleanup_installed == Process.pid
        @cleanup_installed = Process.pid
        at_exit { FileUtils.rm_rf(root) }
      end
      FileUtils.mkdir_p(root)
      dir = Dir.mktmpdir(prefix, root)
      return dir unless block_given?
      begin
        yield dir
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    # A port nothing listens on, from the OS
    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    # Runs the block with a fresh {Protostar.generated_pool} and
    # {Protostar::Types.registry}, for tests of code that only knows the
    # process-wide ones (evaluated `_pb.rb` sources, `Types.define` with no
    # registry). Both are put back afterwards.
    # @yieldparam pool [Protostar::Schema::Pool]
    # @yieldparam registry [Protostar::Types::Registry]
    def isolated_globals
      pool = Protostar::Schema::Pool.new
      registry = Protostar::Types::Registry.new
      saved = [Protostar.generated_pool, Protostar::Types.registry]
      # Both are plain module ivars with readers only; swapping the ivar is the hook
      Protostar.instance_variable_set(:@generated_pool, pool)
      Protostar::Types.instance_variable_set(:@registry, registry)
      yield pool, registry
    ensure
      Protostar.instance_variable_set(:@generated_pool, saved[0])
      Protostar::Types.instance_variable_set(:@registry, saved[1])
    end

    # File names in the process-wide pool and registry
    def global_files
      registry = Protostar::Types.registry.instance_variable_get(:@files).keys
      (Protostar.generated_pool.files.map(&:name) + registry).to_set
    end

    # Fails the run when anything under the directory (test/corpus/ unless
    # told otherwise) was added, removed or touched by the end of the run
    def watch_corpus(dir = CORPUS)
      before = stamp(dir)
      Minitest.after_run do
        next if stamp(dir) == before
        warn "#{dir} changed during the test run, and it is read-only (a checkout restores it)"
        exit 1
      end
    end

    # Every path under the directory with its mtime and size
    def stamp(dir)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.map do |rel|
        stat = File.lstat(File.join(dir, rel))
        [rel, stat.mtime.to_r, stat.size]
      end
    end
  end

  # Included into every Minitest::Test
  module Isolation
    def before_setup
      @_global_files = TestSupport.global_files
      super
    end

    def after_teardown
      super
      @_tmpdirs&.each { |dir| FileUtils.rm_rf(dir) }
      leaked = TestSupport.global_files - @_global_files - TestSupport::GLOBAL_FILES
      unless leaked.empty?
        flunk "left #{leaked.to_a.join(", ")} in the process-wide pool or registry; " \
          "use a Registry and Pool of the test's own, or TestSupport.isolated_globals"
      end
    end

    # A fresh directory under {TestSupport.tmp_root}, removed when the block
    # returns or, without a block, in teardown
    def tmpdir(prefix = "t", &block)
      return TestSupport.tmpdir(prefix, &block) if block
      (@_tmpdirs ||= []) << TestSupport.tmpdir(prefix)
      @_tmpdirs.last
    end

    # @see TestSupport.free_port
    def free_port
      TestSupport.free_port
    end
  end
end

Minitest::Test.include(TestSupport::Isolation)
