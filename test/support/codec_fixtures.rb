# frozen_string_literal: true

# Message classes and enum modules defined from corpus goldens. Each golden
# gets its own pool and registry, so that goldens defining the same names
# never meet; both are built once per process.
module CodecFixtures
  Set = Struct.new(:pool, :registry, :file, :types) do
    # @return [Class, Module]
    def [](full_name)
      types.fetch(full_name)
    end
  end

  @cache = {}
  @mutex = Mutex.new

  # @param relative [String] e.g. "google/protobuf/unittest.proto"
  # @return [Set]
  def self.load(relative)
    @mutex.synchronize do
      @cache[relative] ||= begin
        pool, file = SchemaFixtures.cached(relative)
        registry = Protostar::Types::Registry.new
        types = {}
        pool.files.each { |f| types.merge!(registry.define(f)) }
        Set.new(pool, registry, file, types.freeze)
      end
    end
  end

  # Every golden in the corpus, relative to the goldens root
  def self.goldens
    Dir[File.join(Corpus::GOLDENS, "**", "*.json")].sort.map do |path|
      path.delete_prefix("#{Corpus::GOLDENS}/").delete_suffix(".json")
    end
  end
end
