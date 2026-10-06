# frozen_string_literal: true

# Runs test files in forked workers, one per core, and reports them as one
# Minitest run. Files are sharded whole, longest first, by the seconds each
# took last time (test/.timings, rewritten after every unfiltered run); the
# Ractor tests get one more worker of their own, which is short-lived.
#
#   ruby -Ilib -Itest test/parallel.rb test/a_test.rb test/b_test.rb -- [minitest options]
#
# JOBS=N sets the number of workers, PARALLEL_TIMINGS=path another timings
# file. `rake test` runs this unless PARALLEL=0 or TEST= names a single file.
require "etc"
require_relative "test_helper"

module ParallelTests
  ROOT = File.expand_path("..", __dir__)
  TIMINGS = ENV.fetch("PARALLEL_TIMINGS", File.join(__dir__, ".timings"))
  RACTOR = /(?:\A|_)ractor_test\.rb\z/
  # Seconds per byte of test file, for files with no timing yet
  GUESS = 0.0002

  # Stands in for a test class the parent never loaded, for reporters that print `klass.name`
  Suite = Struct.new(:name) do
    def to_s = name
  end

  class << self
    # @param files [Array<String>] paths relative to the repository
    # @param workers [Integer]
    # @param timings [Hash{String => Float}] seconds per file
    # @return [Array<Array<String>>] the files of each worker, the Ractor tests last, in a shard of their own
    def shards(files, workers, timings = {})
      ractor, rest = files.partition { |f| RACTOR.match?(File.basename(f)) }
      bins = Array.new(workers.clamp(1, [rest.size, 1].max)) { [0.0, []] }
      rest.sort_by { |f| [-weight(f, timings), f] }.each do |f|
        bin = bins.min_by(&:first)
        bin[0] += weight(f, timings)
        bin[1] << f
      end
      (bins.map(&:last) + [ractor]).reject(&:empty?)
    end

    def weight(file, timings)
      timings.fetch(file) { File.size(File.join(ROOT, file)) * GUESS }
    end

    # @return [Hash{String => Float}]
    def read_timings(path = TIMINGS)
      return {} unless File.file?(path)
      File.readlines(path, chomp: true).filter_map do |line|
        seconds, file = line.split(" ", 2)
        [file, Float(seconds)] if file
      end.to_h
    rescue ArgumentError
      {}
    end

    def write_timings(timings, path = TIMINGS)
      File.write(path, timings.sort.map { |file, seconds| format("%.3f %s\n", seconds, file) }.join)
    end

    def relative(path)
      File.expand_path(path).delete_prefix("#{ROOT}/")
    end

    # Replaces Minitest.__run in the parent: forks the workers and feeds what
    # they report into the parent's reporter
    def run(files, reporter, options, workers: Integer(ENV.fetch("JOBS", Etc.nprocessors)))
      timings = read_timings
      running = shards(files, workers, timings).map { |shard| start(shard, options) }
      finished = {}
      readers = running.map { |w| w[:io] }
      until readers.empty?
        IO.select(readers)[0].each do |io|
          message = receive(io)
          next readers.delete(io) unless message
          kind, *args = message
          case kind
          when :prerecord then reporter.prerecord(Suite.new(args[0]), args[1])
          when :record then reporter.record(args[0])
          when :timing then timings[args[0]] = args[1]
          when :done then finished[io] = true
          end
        end
      end
      running.each do |w|
        _, status = Process.wait2(w.delete(:pid))
        next if finished[w[:io]] && status.success?
        reporter.record(crashed(w[:files], status))
      end
      unfiltered = !options[:filter] && !options[:exclude]
      write_timings(timings) if unfiltered && finished.size == running.size
    ensure
      running&.each do |w|
        Process.kill("TERM", w[:pid]) if w[:pid]
      rescue Errno::ESRCH
      end
    end

    private

    def start(files, options)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        work(files, options, writer)
      end
      writer.close
      {pid: pid, io: reader, files: files}
    end

    # The child's whole life. It leaves with exit! so that the at_exit hooks
    # it inherited (Minitest's autorun among them) stay the parent's
    def work(files, options, out)
      reporter = Pipe.new(out)
      files.each do |file|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        before = Minitest::Runnable.runnables.dup
        begin
          require File.join(ROOT, file)
        rescue StandardError, ScriptError => e
          reporter.record(failed(file, e))
        end
        (Minitest::Runnable.runnables - before).shuffle.each { |suite| suite.run(reporter, options) }
        reporter.post(:timing, file, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      end
      reporter.post(:done)
      status = 0
    rescue Exception => e # rubocop:disable Lint/RescueException
      warn "worker #{Process.pid} died in #{files.inspect}: #{e.class}: #{e.message}\n  #{e.backtrace&.join("\n  ")}"
      status = 1
    ensure
      FileUtils.rm_rf(TestSupport.tmp_root)
      $stdout.flush
      $stderr.flush
      exit!(status || 1)
    end

    def receive(io)
      header = io.read(4)
      return unless header&.bytesize == 4
      Marshal.load(io.read(header.unpack1("N"))) # rubocop:disable Security/MarshalLoad
    end

    def crashed(files, status)
      error = RuntimeError.new("a worker running #{files.join(", ")} stopped before reporting every test; its output is above")
      error.set_backtrace([__FILE__])
      failed("worker exited with #{status.exitstatus || status.inspect}", error)
    end

    def failed(name, error)
      result = Minitest::Result.new(name)
      result.klass = "ParallelTests"
      result.failures << Minitest::UnexpectedError.new(error)
      result
    end
  end

  # The child's reporter: every call goes down the pipe to the parent
  class Pipe < Minitest::AbstractReporter
    def initialize(io)
      super()
      @io = io
    end

    def prerecord(klass, name)
      post(:prerecord, klass.name, name)
    end

    def record(result)
      post(:record, result)
    rescue TypeError
      post(:record, plain(result))
    end

    def post(*message)
      bytes = Marshal.dump(message)
      @io.write([bytes.bytesize].pack("N"), bytes)
    end

    private

    # A result whose failures held something Marshal refuses, with those
    # failures replaced by their message and backtrace
    def plain(result)
      copy = result.dup
      copy.failures = result.failures.map do |failure|
        error = RuntimeError.new("#{failure.class}: #{failure.message}")
        error.set_backtrace(failure.backtrace)
        failure.is_a?(Minitest::Skip) ? Minitest::Skip.new(failure.message) : Minitest::UnexpectedError.new(error)
      end
      copy
    end
  end

  # Prepended to Minitest's singleton when this file is the program
  module Run
    def __run(reporter, options)
      ParallelTests.run(ParallelTests::FILES, reporter, options)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  split = ARGV.index("--") || ARGV.size
  ParallelTests::FILES = ARGV[0...split].map { |f| ParallelTests.relative(f) }.freeze
  ARGV.replace(ARGV[(split + 1)..] || [])
  Minitest.singleton_class.prepend(ParallelTests::Run)
end
