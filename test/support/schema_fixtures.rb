# frozen_string_literal: true

# Builds corpus goldens into Schema pools for tests
module SchemaFixtures
  @cache = {}
  @mutex = Mutex.new

  # Builds a golden's files, dependencies first, into a fresh pool
  # @param relative [String] e.g. "google/protobuf/unittest.proto"
  # @return [Array(Protostar::Schema::Pool, Protostar::Schema::File)] the pool and the proto's own file
  def self.load(relative)
    pool = Protostar::Schema::Pool.new
    GoldenHash.load(Corpus.golden(relative, :json)).each do |hash|
      pool.add(Protostar::Schema::Builder.build(hash, pool: pool))
    end
    [pool, pool.file(relative)]
  end

  # Same as {load}, built once per process. Do not add to the returned pool
  def self.cached(relative)
    @mutex.synchronize { @cache[relative] ||= load(relative) }
  end

  # Builds a hand-written file into the pool and adds it
  def self.add(pool, hash)
    pool.add(Protostar::Schema::Builder.build(hash, pool: pool))
  end
end
