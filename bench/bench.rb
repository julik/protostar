# frozen_string_literal: true

# The harness every benchmark in bench/ uses. A benchmark file declares rows:
#
#   Bench.section "Codec" do |s|
#     s.row("decode TestAllTypes") { klass.decode(bytes) }
#     s.row("decode TestAllTypes", side: :google) { gklass.decode(bytes) }
#   end
#
# `side` says which implementation a row measures: protostar's own code, or
# the google-protobuf C extension. A process measures one side
# (`BENCH_SIDE`, default protostar); rows of the other side are skipped and
# their setup never runs. Run a file alone to print its rows, or run
# bench/run.rb (`rake bench`) for the whole table.
#
# Each row reports the median time per call over batches lasting about
# 50 ms, after a short warmup. There are no gems involved, so a file runs
# with a plain `ruby` as well as under Bundler or with a GEM_HOME that has
# only google-protobuf in it.
require "json"

module Bench
  SIDES = %i[protostar google].freeze
  BATCH = 0.05 # seconds per batch
  BUDGET = Float(ENV.fetch("BENCH_SECONDS", "1.0")) # seconds of measurement per row

  @results = []
  @side = (ENV["BENCH_SIDE"] || "protostar").to_sym
  @only = ENV["BENCH_ONLY"]&.then { |s| Regexp.new(s, Regexp::IGNORECASE) }

  class << self
    attr_reader :results, :side

    def section(title)
      yield Section.new(title)
    end

    def google?
      @side == :google
    end

    def wanted?(section, side)
      side == @side && (@only.nil? || @only.match?(section))
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Median seconds per call of the block
    def measure
      n = 1
      loop do
        t = now
        n.times { yield }
        elapsed = now - t
        break if elapsed >= BATCH / 4 || n >= 1 << 20
        n *= 2
      end
      t = now
      n.times { yield } # warmup at the calibrated size
      per = (now - t) / n
      batch = [(BATCH / per).ceil, 1].max
      samples = []
      deadline = now + BUDGET
      while samples.size < 3 || (now < deadline && samples.size < 1000)
        t = now
        batch.times { yield }
        samples << (now - t) / batch
      end
      samples.sort[samples.size / 2]
    end

    # Best of `runs` single calls, for operations that take seconds. `prepare`
    # runs before each call, untimed, and its result is passed to the block.
    def best(runs, prepare = nil)
      Array.new(runs) do
        arg = prepare&.call
        t = now
        yield arg
        now - t
      end.min
    end

    # Objects allocated by one call of the block
    def allocations
      GC.start
      GC.disable
      before = GC.stat(:total_allocated_objects)
      yield
      GC.stat(:total_allocated_objects) - before
    ensure
      GC.enable
    end

    def record(section, label, seconds, note: nil)
      @results << {section: section, label: label, side: @side, seconds: seconds, note: note}
      warn format("  %-58s %s", "#{section}: #{label}", format_time(seconds)) if ENV["BENCH_VERBOSE"]
    end

    def format_time(seconds)
      if seconds >= 1
        format("%.2f s", seconds)
      elsif seconds >= 1e-3
        format("%.1f ms", seconds * 1e3)
      elsif seconds >= 1e-5
        format("%.1f µs", seconds * 1e6)
      else
        format("%.2f µs", seconds * 1e6)
      end
    end

    # What a process prints at exit: JSON lines for bench/run.rb, else a list
    def report(io = $stdout)
      if ENV["BENCH_JSON"]
        io.puts JSON.generate(meta: RUBY_DESCRIPTION)
        @results.each { |r| io.puts JSON.generate(r) }
      else
        io.puts "#{RUBY_DESCRIPTION} (#{@side})"
        @results.each do |r|
          value = r[:count] ? "#{r[:count]} objects" : format_time(r[:seconds])
          io.puts format("%-70s %12s%s", "#{r[:section]}: #{r[:label]}", value, r[:note] ? "  #{r[:note]}" : "")
        end
      end
    end
  end

  class Section
    def initialize(title)
      @title = title
    end

    # Measures a fast operation (microseconds to milliseconds)
    def row(label, side: :protostar, note: nil, &block)
      return unless Bench.wanted?(@title, side)
      Bench.record(@title, label, Bench.measure(&block), note: note)
    end

    # Measures a slow operation as the best of `runs` calls
    def slow(label, runs: 3, side: :protostar, note: nil, prepare: nil, &block)
      return unless Bench.wanted?(@title, side)
      Bench.record(@title, label, Bench.best(runs, prepare, &block), note: note)
    end

    # Records a count instead of a time (allocations); shown as a number
    def count(label, side: :protostar)
      return unless Bench.wanted?(@title, side)
      Bench.results << {section: @title, label: label, side: Bench.side, count: yield}
    end

    # Runs setup only when a row of this side will be measured
    def setup(side: :protostar)
      yield if Bench.wanted?(@title, side)
    end
  end
end

at_exit { Bench.report if $!.nil? || $!.is_a?(SystemExit) && $!.success? }
