# frozen_string_literal: true

# Paths into the vendored protobuf corpus and its protoc goldens. Goldens are
# committed, so tests never need protoc themselves.
module Corpus
  ROOT = File.expand_path("../corpus", __dir__)
  PROTOBUF = File.join(ROOT, "protobuf")
  GOLDENS = File.join(ROOT, "goldens")

  # Include roots in the order protoc was given them when the goldens were made
  INCLUDE_ROOTS = [
    File.join(PROTOBUF, "src"),
    PROTOBUF,
    File.join(PROTOBUF, "ruby", "tests"),
    File.join(PROTOBUF, "src", "google", "protobuf", "compiler", "ruby")
  ].freeze

  def self.protos
    Dir[File.join(PROTOBUF, "**", "*.proto")].sort
  end

  # The golden for a proto, keyed by its path relative to the include root
  # protoc resolved it under. `kind` is :binpb or :json
  def self.golden(relative_path, kind)
    ext = {binpb: ".binpb", json: ".json"}.fetch(kind)
    File.join(GOLDENS, relative_path + ext)
  end
end
