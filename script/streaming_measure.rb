# frozen_string_literal: true

# Measures what Protostar::Builder holds in memory while it streams, one
# message shape per degree of streaming in docs/concepts/streaming.md.
# "Held" is the peak of ObjectSpace.memsize_of_all over Strings and Arrays,
# after a full GC, minus the same before the build, sampled inside the
# block and inside the sink (so a copy made just before a write is seen).
# Times come from a second run without sampling.
#
#   ruby -Ilib script/streaming_measure.rb            # 100 MB per shape
#   MB=10 ONLY=chunk ruby -Ilib script/streaming_measure.rb

require "protostar"
require "objspace"

module StreamingMeasure
  PROTO = <<~PROTO
    edition = "2023";
    package streaming;

    message Node {
      string text = 1;
      Node child = 2;
      repeated string lines = 3;
      repeated int32 nums = 4;
    }

    message Root {
      repeated string lines = 1;
      Node node = 2;
      repeated Node nodes = 3;
      Node flat = 4 [features.message_encoding = DELIMITED];
      repeated int32 nums = 5;
      repeated int32 loose = 6 [features.repeated_field_encoding = EXPANDED];
    }
  PROTO

  TYPES = begin
    files = Protostar::Compiler.new.compile(["streaming.proto"], sources: {"streaming.proto" => PROTO})
    registry = Protostar::Types::Registry.new
    files.each_with_object({}) { |f, h| h.merge!(registry.define(f)) }
  end
  ROOT = TYPES.fetch("streaming.Root")
  LINE = ("x" * 1021).freeze # 1 KiB with tag and length
  MB = Integer(ENV.fetch("MB", "100"))
  STREAMING = Protostar::Builder.instance_method(:initialize).parameters.any? { |_, n| n == :chunk_nested_at }

  # Discards what it is given, counting bytes and writes, sampling memory
  class Sink
    attr_reader :bytes, :writes

    def initialize(probe)
      @probe = probe
      @bytes = 0
      @writes = 0
    end

    def write(s)
      # a large write is the moment a copy, if any, is alive
      (s.bytesize >= 1_048_576) ? @probe&.sample : @probe&.tick
      @bytes += s.bytesize
      @writes += 1
      s.bytesize
    end
  end

  class Probe
    attr_reader :peak

    def initialize(every)
      @every = every
      @n = 0
      @peak = 0
      GC.start
      @base = now
    end

    def now
      ObjectSpace.memsize_of_all(String) + ObjectSpace.memsize_of_all(Array)
    end

    def tick
      @n += 1
      sample if (@n % @every).zero?
    end

    def sample
      GC.start
      held = now - @base
      @peak = held if held > @peak
    end
  end

  NULL = Object.new
  def NULL.tick = nil

  module_function

  def lines(pb, probe, count)
    count.times do
      pb.lines LINE
      probe.tick
    end
  end

  def chain(pb, probe, depth, count)
    return lines(pb, probe, count) if depth.zero?
    pb.child { chain(pb, probe, depth - 1, count) }
  end

  K = MB * 1024 # 1 KiB lines in MB megabytes
  RUN = Array.new(1000, 300).freeze
  SHAPES = {
    "top" => ["top-level repeated string, #{MB} MB", {}, ->(pb, p) { lines(pb, p, K) }],
    "children" => ["#{MB * 10} top-level nested messages of 100 KB", {}, ->(pb, p) { pb.nodes(1..MB * 10) { lines(pb, p, 100) } }],
    "nested" => ["one nested message of #{MB} MB", {}, ->(pb, p) { pb.node { lines(pb, p, K) } }],
    "nested2" => ["#{MB} MB two levels down", {}, ->(pb, p) { pb.node { pb.child { lines(pb, p, K) } } }],
    "depth1" => ["10 MB under 1 level", {}, ->(pb, p) { pb.node { chain(pb, p, 0, 10 * 1024) } }],
    "depth10" => ["10 MB under 10 levels", {}, ->(pb, p) { pb.node { chain(pb, p, 9, 10 * 1024) } }],
    "depth100" => ["10 MB under 100 levels", {}, ->(pb, p) { pb.node { chain(pb, p, 99, 10 * 1024) } }],
    "chunk" => ["one nested message of #{MB} MB, chunk_nested_at: 64 KiB", {chunk_nested_at: 65_536}, ->(pb, p) { pb.node { lines(pb, p, K) } }],
    "chunk2" => ["#{MB} MB two levels down, chunk_nested_at: 64 KiB", {chunk_nested_at: 65_536}, ->(pb, p) { pb.node { pb.child { lines(pb, p, K) } } }],
    "chunk100" => ["10 MB under 100 levels, chunk_nested_at: 64 KiB", {chunk_nested_at: 65_536}, ->(pb, p) { pb.node { chain(pb, p, 99, 10 * 1024) } }],
    "delimited" => ["#{MB} MB in a DELIMITED message field", {}, ->(pb, p) { pb.flat { lines(pb, p, K) } }],
    "packed" => ["10 M packed int32, 1,000 per call", {}, ->(pb, p) { 10_000.times { pb.nums(RUN) && p.tick } }],
    "expanded" => ["10 M expanded int32, 1,000 per call", {}, ->(pb, p) { 10_000.times { pb.loose(RUN) && p.tick } }],
    "buffer0" => ["top-level repeated string, #{MB} MB, buffer: 0", {buffer: 0}, ->(pb, p) { lines(pb, p, K) }]
  }.freeze

  def run(name, options, shape, sample)
    probe = sample ? Probe.new(1000) : NULL
    sink = Sink.new(sample ? probe : nil)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Protostar::Builder.write(sink, ROOT, **options) { |pb| shape.call(pb, probe) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    probe.sample if sample
    [sink, elapsed, sample && probe.peak]
  end

  def sequence(sample)
    probe = sample ? Probe.new(1000) : NULL
    sink = Sink.new(sample ? probe : nil)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Protostar::Builder.each(sink, ROOT, 1..MB * 10) { |pb, _| lines(pb, probe, 100) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    probe.sample if sample
    [sink, elapsed, sample && probe.peak]
  end

  def mb(n) = format("%.2f MB", n / 1_048_576.0)

  def report
    only = ENV["ONLY"]&.split(",")
    rows = SHAPES.filter_map do |name, (title, options, shape)|
      next if only && !only.include?(name)
      next if !options.empty? && !STREAMING
      warn name
      sink, _, held = run(name, options, shape, true)
      _, elapsed = run(name, options, shape, false)
      [name, title, mb(sink.bytes), sink.writes, mb(held), format("%.2f s", elapsed)]
    end
    if STREAMING && (!only || only.include?("each"))
      sink, _, held = sequence(true)
      _, elapsed = sequence(false)
      rows << ["each", "#{MB * 10} length-prefixed messages of 100 KB", mb(sink.bytes), sink.writes, mb(held), format("%.2f s", elapsed)]
    end
    puts "Ruby #{RUBY_VERSION}#{" +YJIT" if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?}, #{MB} MB"
    puts "| shape | | out | sink writes | held at peak | time |"
    puts "|---|---|---|---|---|---|"
    rows.each { |r| puts "| #{r.join(" | ")} |" }
  end
end

StreamingMeasure.report if $PROGRAM_NAME == __FILE__
