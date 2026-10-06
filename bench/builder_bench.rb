# frozen_string_literal: true

# WS9's measurement without Rails: a person with 1,000 friends, each with
# two names, two tags, a flag, a nested asset with three URLs and a
# two-entry map (about 200 KB encoded), written as bytes three ways:
# streamed by Protostar::Builder, built as messages and encoded, and (for
# google-protobuf) built as messages and encoded.
#
#   ruby bench/builder_bench.rb
#   BENCH_SIDE=google ruby bench/builder_bench.rb

require_relative "bench"
require_relative "fixtures"

Bench.section "Builder" do |s|
  types = BenchFixtures.people
  person = types.fetch("bench.Person")
  racers = BenchFixtures.racers

  build = lambda do
    Protostar::Builder.build(person) do |pb|
      pb.name "Team"
      pb.friends(racers) do |r|
        pb.name r.name
        pb.last_name r.last_name
        pb.tags r.tags
        pb.active r.active
        pb.logo do
          pb.url r.url
          pb.thumb_url "#{r.url}?w=64"
          pb.retina_url "#{r.url}?w=512"
        end
        pb.attrs r.attrs
      end
    end
  end
  objects = lambda do
    person.new(name: "Team", friends: racers.map { |r| BenchFixtures.person_hash(r) }).encode
  end
  raise "builder and encode disagree" unless person.decode(build.call) == person.decode(objects.call)
  size = build.call.bytesize

  s.row("1,000 friends (#{size / 1000} KB): Protostar::Builder.build") { build.call }
  s.row("1,000 friends: new from Hashes, then encode") { objects.call }
  s.setup(side: :google) do
    g = BenchFixtures.google_people.lookup("bench.Person").msgclass
    s.row("1,000 friends: new from Hashes, then encode", side: :google) do
      g.encode(g.new(name: "Team", friends: racers.map { |r| BenchFixtures.person_hash(r) }))
    end
  end

  s.count("objects allocated: 1,000 friends, Protostar::Builder.build") { Bench.allocations { build.call } }
  s.count("objects allocated: 1,000 friends, new from Hashes, then encode") { Bench.allocations { objects.call } }
end
