# frozen_string_literal: true

# Builds corpus goldens into Schema pools for tests
module SchemaFixtures
  @cache = {}
  @mutex = Mutex.new

  # Builds a golden's files, dependencies first, into a fresh pool, through
  # Schema::File.from_proto from the `.binpb` protoc wrote (source info left out)
  # @param relative [String] e.g. "google/protobuf/unittest.proto"
  # @return [Array(Protostar::Schema::Pool, Protostar::Schema::File)] the pool and the proto's own file
  def self.load(relative)
    pool = Protostar::Schema::Pool.new
    types = Protostar::Schema::Proto.types
    types::FileDescriptorSet.decode(File.binread(Corpus.golden(relative, :binpb))).file.each do |proto|
      proto.clear_source_code_info
      pool.add(Protostar::Schema::File.from_proto(proto, pool: pool))
    end
    [pool, pool.file(relative)]
  end

  # Same as {load}, built once per process. Do not add to the returned pool
  def self.cached(relative)
    @mutex.synchronize { @cache[relative] ||= load(relative) }
  end

  # A file written as protoc's FileDescriptorProto (a Hash in its `to_h`
  # spelling), read through Schema::File.from_proto; not added to the pool
  # @return [Protostar::Schema::File]
  def self.from_proto(hash, pool)
    proto = Protostar::Schema::Proto.types::FileDescriptorProto.new(hash)
    Protostar::Schema::File.from_proto(proto, pool: pool)
  end

  # Drafts a file, resolves it against the pool and adds it
  # @yieldparam f [Protostar::Schema::Draft::File]
  def self.add(pool, name, **kwargs)
    draft = Protostar::Schema::File.draft(name, **kwargs)
    yield draft if block_given?
    pool.add(draft.resolve(pool).freeze!)
  end
end
