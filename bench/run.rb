# frozen_string_literal: true

# Runs every benchmark in bench/ (`rake bench`) and prints one table:
# protostar and the google-protobuf C extension, each with YJIT off and on.
#
#   ruby bench/run.rb                          # print the table
#   ruby bench/run.rb --write                  # also put it into docs/benchmarks.md
#   BENCH_ONLY=codec ruby bench/run.rb         # sections matching a pattern
#   BENCH_SECONDS=2 ruby bench/run.rb          # longer per row (default 1)
#
# Each side and YJIT setting runs in a process of its own, with no Bundler.
# google-protobuf is installed into tmp/bench/<ruby version>/gem_home, a
# GEM_HOME that holds nothing else, the first time it is needed; protostar's
# own bundle never sees it. Without network access, or on a Ruby it has no
# build for, its columns stay empty. YJIT columns are empty on a Ruby built
# without YJIT. Numbers are reported, never checked.
require "json"
require "open3"
require "rbconfig"
require "fileutils"

module BenchRun
  ROOT = File.expand_path("..", __dir__)
  GOOGLE_VERSION = "4.36.2"
  DOC = File.join(ROOT, "docs", "benchmarks.md")
  START = "<!-- rake bench: start -->"
  FINISH = "<!-- rake bench: end -->"
  COLUMNS = [[:protostar, false], [:protostar, true], [:google, false], [:google, true]].freeze
  HEADINGS = ["protostar", "protostar, YJIT", "google-protobuf #{GOOGLE_VERSION} (C)", "google-protobuf (C), YJIT"].freeze

  module_function

  def ruby
    RbConfig.ruby
  end

  def clean_env
    ENV.to_h.reject { |k, _| k.start_with?("BUNDLE_", "BUNDLER_") || %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH].include?(k) }
  end

  def yjit?
    _, status = Open3.capture2e(clean_env, ruby, "--yjit", "-e", "exit(RubyVM::YJIT.enabled? ? 0 : 1)",
      unsetenv_others: true)
    status.success?
  end

  def gem_home
    File.join(ROOT, "tmp", "bench", RUBY_VERSION, "gem_home")
  end

  def google_env
    clean_env.merge("GEM_HOME" => gem_home, "GEM_PATH" => gem_home)
  end

  # google-protobuf in a GEM_HOME of its own; false when it cannot be had
  def google?
    probe = ["-e", "gem 'google-protobuf', '= #{GOOGLE_VERSION}'; require 'google/protobuf'"]
    return true if Open3.capture2e(google_env, ruby, *probe, unsetenv_others: true)[1].success?
    FileUtils.mkdir_p(gem_home)
    warn "installing google-protobuf #{GOOGLE_VERSION} into #{gem_home}"
    out, status = Open3.capture2e(google_env, ruby, "-S", "gem", "install", "google-protobuf", "-v", GOOGLE_VERSION,
      "--no-document", unsetenv_others: true)
    warn out unless status.success?
    status.success? && Open3.capture2e(google_env, ruby, *probe, unsetenv_others: true)[1].success?
  end

  def measure(side, yjit)
    env = (side == :google) ? google_env : clean_env
    env = env.merge("BENCH_SIDE" => side.to_s, "BENCH_JSON" => "1")
    %w[BENCH_ONLY BENCH_SECONDS BENCH_CORPUS].each { |k| env[k] = ENV[k] if ENV[k] }
    args = [ruby]
    args << "--yjit" if yjit
    args << File.join(__dir__, "all.rb")
    warn "running #{side}#{" with YJIT" if yjit}"
    out, err, status = Open3.capture3(env, *args, unsetenv_others: true)
    abort "#{side} #{"YJIT " if yjit}failed:\n#{err}" unless status.success?
    out.lines.map { |l| JSON.parse(l, symbolize_names: true) }
  end

  def format_time(seconds)
    if seconds >= 1 then format("%.2f s", seconds)
    elsif seconds >= 1e-3 then format("%.1f ms", seconds * 1e3)
    elsif seconds >= 1e-5 then format("%.1f µs", seconds * 1e6)
    else format("%.2f µs", seconds * 1e6)
    end
  end

  def table(runs)
    rows = {}
    counts = {}
    runs.each_with_index do |results, column|
      results.each do |r|
        next if r[:meta]
        if r[:count]
          counts[[r[:section], r[:label]]] ||= r[:count] if column.zero?
        else
          (rows[[r[:section], r[:label]]] ||= Array.new(COLUMNS.size))[column] = r[:seconds]
        end
      end
    end
    shown = (0...COLUMNS.size).select { |i| !runs[i].empty? }
    out = +""
    rows.group_by { |(section, _), _| section }.each do |section, entries|
      out << "\n### #{section}\n\n"
      out << "| | #{HEADINGS.values_at(*shown).join(" | ")} |\n|---|#{"---:|" * shown.size}\n"
      entries.each do |(_, label), values|
        cells = values.values_at(*shown).map { |v| v ? format_time(v) : "" }
        out << "| #{label} | #{cells.join(" | ")} |\n"
      end
    end
    unless counts.empty?
      out << "\n### Allocations (protostar, objects per call)\n\n| | objects |\n|---|---:|\n"
      counts.each { |(section, label), n| out << "| #{section}: #{label} | #{n} |\n" }
    end
    out
  end

  def header(runs)
    meta = runs.compact.flat_map { |r| r.select { |x| x[:meta] } }
    ruby = meta.first&.dig(:meta) || RUBY_DESCRIPTION
    cpu = begin
      `sysctl -n machdep.cpu.brand_string 2>/dev/null`.strip
    rescue
      ""
    end
    cpu = RbConfig::CONFIG["host"] if cpu.empty?
    "#{ruby.sub(/ \+YJIT.*?(?= \[)/, "")}, #{cpu}, #{Time.now.strftime("%Y-%m-%d")}. " \
      "Time per call; an empty cell has no counterpart on that side.\n"
  end

  def call(write: false)
    yjit = yjit?
    google = google?
    runs = COLUMNS.map do |side, with_yjit|
      next [] if with_yjit && !yjit
      next [] if side == :google && !google
      measure(side, with_yjit)
    end
    text = header(runs) + table(runs)
    puts text
    write_doc(text) if write
  end

  def write_doc(text)
    doc = File.read(DOC)
    from = doc.index(START) or abort "#{DOC} has no #{START} marker"
    to = doc.index(FINISH) or abort "#{DOC} has no #{FINISH} marker"
    File.write(DOC, doc[0, from + START.size] + "\n" + text + "\n" + doc[to..])
    warn "wrote #{DOC}"
  end
end

BenchRun.call(write: ARGV.include?("--write"))
