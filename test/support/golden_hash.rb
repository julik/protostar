# frozen_string_literal: true

require "json"

# Reads a golden `.json` (protoc's FileDescriptorSet in the proto3 JSON
# mapping) with protostar's own JSON parser into the bootstrap's
# descriptor.proto messages, and gives them as Hashes the way `to_h` does:
# Symbol keys, enum values as Symbols, 64-bit integers as Integers, bytes as
# binary Strings. A Schema::File compares with them through `to_proto.to_h`.
#
# The goldens were printed by google-protobuf 4.31, which wrote editions its
# descriptor.proto had no name for (EDITION_2026, EDITION_UNSTABLE) as
# numbers; the parser names them from today's descriptor.proto.
module GoldenHash
  # @param path [String] a golden .json
  # @return [Array<Hash>] one FileDescriptorProto Hash per file, in protoc's
  #   order (dependencies before dependents)
  def self.load(path)
    messages(path).map(&:to_h)
  end

  # @param path [String] a golden .json
  # @return [Array<Protostar::Google::Protobuf::FileDescriptorProto>]
  def self.messages(path)
    Protostar::Schema::Proto.types::FileDescriptorSet.decode_json(File.read(path)).file.to_a
  end

  # @param json [Object] parsed JSON for a message of the given descriptor.proto type
  # @param type [String] full name of a descriptor.proto message, e.g. "google.protobuf.FileDescriptorProto"
  # @return [Hash]
  def self.convert(json, type)
    klass = Protostar::Schema::Proto.types.const_get(type.delete_prefix("google.protobuf."))
    klass.decode_json(JSON.generate(json)).to_h
  end
end
