# frozen_string_literal: true

# The google-protobuf gem as a cross-check, for tests run with PROTOSTAR_ORACLE=1
# and a bundle installed with BUNDLE_WITH=oracle
module Oracle
  EDITION_KEYS = %i[edition edition_introduced edition_deprecated edition_removed minimum_edition maximum_edition].freeze

  def self.available?
    return false unless ENV["PROTOSTAR_ORACLE"]
    require "google/protobuf"
    require "google/protobuf/descriptor_pb"
    true
  rescue LoadError
    false
  end

  # The FileDescriptorProto hashes of a .binpb golden, as google-protobuf's
  # `to_h` gives them. Editions its own descriptor.proto has no name for come
  # back as Integers; they are named here as protostar's descriptor.proto names them.
  def self.file_hashes(binpb_path, source_info: false)
    set = Google::Protobuf::FileDescriptorSet.decode(File.binread(binpb_path))
    set.file.map do |file|
      file.clear_source_code_info unless source_info
      name_editions(file.to_h)
    end
  end

  def self.name_editions(value, key = nil)
    case value
    when Hash then value.to_h { |k, v| [k, name_editions(v, k)] }
    when Array then value.map { |v| name_editions(v, key) }
    when Integer
      return value unless EDITION_KEYS.include?(key)
      Protostar::Schema::Features::EDITION_NAMES.fetch(value, value)
    else value
    end
  end

  @pools = {}
  @pools_mutex = Mutex.new

  # A google-protobuf DescriptorPool holding every file of a golden's set,
  # built once per process
  # @param relative [String] e.g. "google/protobuf/unittest.proto"
  def self.pool(relative)
    @pools_mutex.synchronize do
      @pools[relative] ||= begin
        pool = Google::Protobuf::DescriptorPool.new
        Google::Protobuf::FileDescriptorSet.decode(File.binread(Corpus.golden(relative, :binpb))).file.each do |file|
          file.clear_source_code_info
          pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))
        end
        pool
      end
    end
  end
end
