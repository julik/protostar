# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# The guards behind test/support/test_support.rb's isolation rules, which
# keep test files independent of each other when they run in parallel
class IsolationTest < Minitest::Test
  ROOT = TestSupport::ROOT
  HELPER = "test/support/test_support.rb"

  def test_temp_dirs_come_only_from_the_helper
    offenders = grep(/Dir\.mktmpdir|Dir\.tmpdir|Tempfile|["'`](?:\/tmp|tmp)\/|["']tmp["']/)
    assert_empty offenders, "use tmpdir (TestSupport.tmpdir) instead of naming or making temp dirs yourself"
  end

  def test_ports_come_only_from_the_helper
    assert_empty grep(/TCPServer\.(?:new|open)/), "use free_port (TestSupport.free_port)"
  end

  def test_env_is_read_at_boot_and_never_written
    writes = grep(/ENV\[[^\]]+\]\s*(?:=[^=~]|\|\|=)|ENV\.(?:store|delete|update|merge!|replace|clear)\b/)
    assert_empty writes, "ENV is process-wide; pass an env Hash to the subprocess instead"
    assert_empty grep(/ENV(?:\[|\.fetch\()"PROTOSTAR_ORACLE"/), "read TestSupport::ORACLE"
  end

  def test_tmpdir_is_under_the_process_own_directory_and_goes_away
    from_block = tmpdir { |dir| assert File.directory?(dir) and dir }
    refute File.exist?(from_block)
    assert from_block.start_with?(File.join(ROOT, "tmp", "test", Process.pid.to_s, ""))

    inner = Class.new(Minitest::Test) do
      attr_reader :dir

      def test_makes_one
        @dir = tmpdir("kept")
        File.write(File.join(@dir, "x"), "x")
      end
    end
    test = inner.new(:test_makes_one)
    assert test.run.passed?
    refute File.exist?(test.dir), "removed in teardown"
  end

  def test_a_file_left_in_the_global_registry_fails_the_test
    file = SchemaFixtures.add(Protostar::Schema::Pool.new, "isolation/leak.proto", package: "isolation.leak") do |f|
      f.message("M") { |m| m.field "a", 1, :int32 }
    end
    inner = Class.new(Minitest::Test) do
      define_method(:test_leaks) { Protostar::Types.define(file) }
      define_method(:test_keeps_to_itself) { Protostar::Types.define(file, registry: Protostar::Types::Registry.new) }
    end
    leaked, kept = TestSupport.isolated_globals do
      [inner.new(:test_leaks).run, inner.new(:test_keeps_to_itself).run]
    end
    assert kept.passed?
    refute leaked.passed?
    assert_includes leaked.failures.first.message, "left isolation/leak.proto in the process-wide pool or registry"
    assert_nil Protostar::Types.find("isolation.leak.M")
  end

  def test_the_corpus_guard_fails_a_run_that_touches_the_corpus
    dir = tmpdir("corpus")
    File.write(File.join(dir, "a.proto"), "")
    script = <<~RUBY
      require "test_helper"
      TestSupport.watch_corpus(#{dir.inspect})
      class Toucher < Minitest::Test
        def test_touches
          File.write(File.join(#{dir.inspect}, "a.proto"), "changed")
        end
      end
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, "-I#{ROOT}/lib", "-I#{ROOT}/test", "-e", script, chdir: ROOT)
    refute status.success?, out
    assert_includes out, "1 runs, 0 assertions, 0 failures, 0 errors, 0 skips"
    assert_includes out, "#{dir} changed during the test run"
  end

  def test_the_oracle_switch_is_a_boolean_read_once
    assert_includes [true, false], TestSupport::ORACLE
    assert TestSupport::ORACLE.frozen?
  end

  private

  # Lines of Ruby under test/ (the corpus, the helper and this file aside) that match
  def grep(pattern)
    Dir.glob("test/**/*.rb", base: ROOT).sort.flat_map do |rel|
      next [] if rel.start_with?("test/corpus/") || [HELPER, "test/parallel/isolation_test.rb"].include?(rel)
      File.foreach(File.join(ROOT, rel)).with_index(1).filter_map do |line, n|
        "#{rel}:#{n}: #{line.strip}" if pattern.match?(line)
      end
    end
  end
end
