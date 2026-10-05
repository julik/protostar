# frozen_string_literal: true

# Renders one pbbuilder template (a message with a repeated nested message
# of 1,000 items, each item fragment-cached) through ActionView in three
# configurations, and prints time and allocations per render:
#
#   google   pbbuilder as published, on the real google-protobuf gem
#   shim     pbbuilder as published, on shims/google-protobuf
#   builder  pbbuilder with llm/outputs/ws9-pbbuilder.patch, on Protostar::Builder
#
# For builder there is a second row, "bytes out": the same template through
# a handler that returns the builder's bytes instead of decoding them into
# the message pbbuilder's handler returns. It exists only here, to show the
# cost of that decode.
#
#   ruby script/pbbuilder_bench.rb [google shim builder]
#   BENCH_YJIT=1 ruby script/pbbuilder_bench.rb     # with --yjit (BENCH_RUNS sets the number of runs)
#
# The google configuration resolves google-protobuf with GEM_HOME pointing
# at tmp/pbbuilder-bench/gem_home, so a missing gem is installed there and
# nowhere else; protostar's own bundle never sees it. Run
# script/pbbuilder_suite.rb shim and builder first: they make the clones.

require "fileutils"
require "open3"
require "bundler"

REPO = File.expand_path("..", __dir__)
CLONE = File.join(REPO, "tmp", "pbbuilder")
FORK = File.join(REPO, "tmp", "pbbuilder-protostar")
DIR = File.join(REPO, "tmp", "pbbuilder-bench")
GEM_HOME = File.join(DIR, "gem_home")
RAILS = "~> 8.1.0"
GOOGLE = "4.36.2"

def gemfile(config)
  path = File.join(DIR, config, "Gemfile")
  FileUtils.mkdir_p(File.dirname(path))
  lines = ["source \"https://rubygems.org\""]
  lines << "gem \"pbbuilder\", path: #{((config == "builder") ? FORK : CLONE).inspect}"
  case config
  when "google" then lines << "gem \"google-protobuf\", #{GOOGLE.inspect}"
  when "shim"
    lines << "gem \"protostar\", path: #{REPO.inspect}"
    lines << "gem \"google-protobuf\", path: #{File.join(REPO, "shims", "google-protobuf").inspect}"
  else lines << "gem \"protostar\", path: #{REPO.inspect}"
  end
  %w[activesupport activemodel actionview actionpack railties].each { |g| lines << "gem #{g.inspect}, #{RAILS.inspect}" }
  lines << "gem \"minitest\", \"~> 5.0\""
  File.write(path, lines.join("\n") << "\n")
  path
end

BENCH = <<~'RUBY'
  require "rails"
  require "active_support"
  require "active_support/cache/memory_store"
  require "active_model"
  require "action_view"
  require "action_controller"
  require "action_view/testing/resolvers"
  require "action_view/test_case"
  require "pbbuilder"
  require "pbbuilder/handler"
  config = ENV.fetch("BENCH_CONFIG")
  if config == "builder"
    require File.join(ENV.fetch("BENCH_PBBUILDER"), "test", "test_proto_pb")
    Person = Pbbuildertest::Person
    impl = "Protostar::Builder"
  else
    require "google/protobuf"
    require "google/protobuf/field_mask_pb"
    require File.join(ENV.fetch("BENCH_PBBUILDER"), "test", "test_proto_pb")
    Person = Google::Protobuf::DescriptorPool.generated_pool.lookup("pbbuildertest.Person").msgclass
    impl = "google-protobuf #{Gem.loaded_specs["google-protobuf"].version} #{Google::Protobuf::IMPLEMENTATION}"
  end

  class << Rails
    def cache
      @cache ||= ActiveSupport::Cache::MemoryStore.new(size: 512 * 1024 * 1024)
    end
  end
  Mime::Type.register "application/vnd.google.protobuf", :pb, [], %w[pb]
  ActionView::Template.register_template_handler :pbbuilder, PbbuilderHandler

  # pbbuilder's handler, returning the bytes written rather than a message
  class BytesHandler
    def self.call(template, source = nil)
      "pb = PbbuilderTemplate.new(self, @_response_class.new); #{source || template.source}\n" \
        "pb.instance_eval { @builder.target! }"
    end
  end
  ActionView::Template.register_template_handler :pbbytes, BytesHandler

  Racer = Struct.new(:id, :name, :tags, :foods) do
    def cache_key = "racer-#{id}"
  end
  RACERS = (1..1000).map do |i|
    Racer.new(i, "Racer #{i}", ["fast", "team #{i % 10}"], {"breakfast" => "eggs #{i}", "dinner" => "pizza"})
  end

  TEMPLATE = <<~PB
    pb.name "Grid"
    pb.friends @racers do |racer|
      pb.cache! racer do
        pb.name racer.name
        pb.last_name "Driver"
        pb.tags racer.tags
        pb.boolean_me racer.id.even?
        pb.logo do
          pb.url "https://cdn.example.com/racers/\#{racer.id}.png"
          pb.url_2x "https://cdn.example.com/racers/\#{racer.id}@2x.png"
          pb.url_3x "https://cdn.example.com/racers/\#{racer.id}@3x.png"
        end
        pb.favourite_foods racer.foods
      end
    end
  PB

  def render_once(handler = :pbbuilder)
    resolver = ActionView::FixtureResolver.new("grid.pb.pbbuilder" => TEMPLATE, "grid.pb.pbbytes" => TEMPLATE)
    lookup = ActionView::LookupContext.new([resolver], {}, [""])
    controller = ActionView::TestCase::TestController.new
    controller.perform_caching = true
    view = ActionView::Base.with_empty_template_cache.new(lookup, {racers: RACERS, _response_class: Person}, controller)
    def view.view_cache_dependencies = []
    def view.combined_fragment_cache_key(key) = [key]
    def view.cache_fragment_name(key, *) = key
    view.render(template: "grid", handlers: [handler], formats: [:pb])
  end

  def allocations
    GC.start
    before = GC.stat(:total_allocated_objects)
    yield
    GC.stat(:total_allocated_objects) - before
  end

  def median_ms(runs)
    times = Array.new(runs) do
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    end
    (times.sort[runs / 2] * 1000).round(1)
  end

  impl += " (YJIT)" if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
  runs = Integer(ENV.fetch("BENCH_RUNS", "15"))
  Rails.cache.clear
  result = render_once
  raise "wrong result" unless result.friends.size == 1000 && result.friends[999].logo.url_3x.end_with?("1000@3x.png")
  digest = result.class.encode(result).bytesize
  3.times { render_once }

  rows = [{
    name: config,
    impl: impl,
    bytes: digest,
    warm_ms: median_ms(runs) { render_once },
    warm_alloc: allocations { render_once },
    warm_encode_ms: median_ms(runs) { r = render_once; r.class.encode(r) },
    cold_ms: median_ms(runs) { Rails.cache.clear; render_once },
    cold_alloc: (Rails.cache.clear; allocations { render_once })
  }]
  if config == "builder"
    Rails.cache.clear
    out = render_once(:pbbytes)
    # fields come in template order, not number order: equal once decoded
    raise "bytes out differ" unless Person.decode(out) == result && out.bytesize == digest
    3.times { render_once(:pbbytes) }
    warm = median_ms(runs) { render_once(:pbbytes) }
    rows << {
      name: "builder, bytes out",
      impl: impl,
      bytes: out.bytesize,
      warm_ms: warm,
      warm_alloc: allocations { render_once(:pbbytes) },
      warm_encode_ms: warm,
      cold_ms: median_ms(runs) { Rails.cache.clear; render_once(:pbbytes) },
      cold_alloc: (Rails.cache.clear; allocations { render_once(:pbbytes) })
    }
  end
  puts "RESULT #{rows.inspect}"
RUBY

def bench(config)
  dir = (config == "builder") ? FORK : CLONE
  abort "#{dir} is missing; run script/pbbuilder_suite.rb #{(config == "builder") ? "builder" : "shim"} first" unless File.directory?(dir)
  env = {"BUNDLE_GEMFILE" => gemfile(config), "BENCH_CONFIG" => config, "BENCH_PBBUILDER" => dir}
  if config == "google"
    FileUtils.mkdir_p(GEM_HOME)
    env["GEM_HOME"] = GEM_HOME
    env["GEM_PATH"] = ([GEM_HOME] + Gem.path).join(File::PATH_SEPARATOR)
  end
  Bundler.with_unbundled_env do
    system(env, "bundle check > /dev/null 2>&1 || bundle install --quiet", chdir: DIR, exception: true)
    ruby = ENV["BENCH_YJIT"] ? %w[ruby --yjit] : %w[ruby]
    out, status = Open3.capture2e(env, "bundle", "exec", *ruby, "-e", BENCH, chdir: DIR)
    abort "#{config} failed:\n#{out}" unless status.success?
    eval(out[/^RESULT (.*)$/, 1]) # rubocop:disable Security/Eval -- our own subprocess's Hash#inspect
  end
end

configs = ARGV.empty? ? %w[google shim builder] : ARGV
rows = configs.flat_map { |c| bench(c) }
puts "Ruby #{RUBY_VERSION}#{" +YJIT" if ENV["BENCH_YJIT"]}, Rails #{RAILS}, 1,000 items, median of #{ENV.fetch("BENCH_RUNS", "15")} runs"
puts "| | implementation | warm cache: ms | warm: allocations | warm, then encode: ms | cold cache: ms | cold: allocations | encoded bytes |"
puts "|---|---|---|---|---|---|---|---|"
rows.each do |r|
  puts "| #{r[:name]} | #{r[:impl]} | #{r[:warm_ms]} | #{r[:warm_alloc]} | #{r[:warm_encode_ms]} | #{r[:cold_ms]} | #{r[:cold_alloc]} | #{r[:bytes]} |"
end
