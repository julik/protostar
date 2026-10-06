# frozen_string_literal: true

require_relative "protostar/version"

# Protocol buffers in pure Ruby: a `.proto` compiler ({Compiler}), message
# classes with a binary codec, views, JSON and the text format, and the
# {DSL} that generated `_pb.rb` files are written in. README.md has the tour.
module Protostar
  # The base of protostar's errors, except {Protostar::TypeError}, which is a
  # Ruby `TypeError` so that `rescue TypeError` catches it
  class Error < StandardError; end

  # Warns in Ruby's `:deprecated` category (shown under `ruby -w` or
  # `-W:deprecated`), naming the first caller outside protostar
  # @api private
  def self.deprecated(old, replacement)
    lib = __dir__ + "/"
    site = caller_locations.find { |l| !l.path.start_with?(lib) }
    where = site ? "#{site.path}:#{site.lineno}: " : ""
    warn("#{where}warning: protostar: #{old} is deprecated and goes away in 0.2.0, write #{replacement} " \
      "(protostar compile writes the new spelling)", category: :deprecated)
  end

  # Short names for the well-known types: `Protostar::Timestamp` is
  # `Protostar::Google::Protobuf::Timestamp`. Each loads its bootstrap file
  # on first use, so `require "protostar"` does not.
  {
    "any" => %i[Any],
    "duration" => %i[Duration],
    "empty" => %i[Empty],
    "field_mask" => %i[FieldMask],
    "struct" => %i[Struct Value ListValue],
    "timestamp" => %i[Timestamp],
    "wrappers" => %i[DoubleValue FloatValue Int64Value UInt64Value Int32Value UInt32Value BoolValue StringValue BytesValue]
  }.each do |file, names|
    path = File.expand_path("protostar/short_names/#{file}", __dir__)
    names.each { |name| autoload(name, path) }
  end
end

require_relative "protostar/errors"
require_relative "protostar/schema"
require_relative "protostar/wire"
require_relative "protostar/unknown_field"
require_relative "protostar/enum"
require_relative "protostar/message"
require_relative "protostar/codec"
require_relative "protostar/types"
require_relative "protostar/well_known"
require_relative "protostar/json"
require_relative "protostar/text"
require_relative "protostar/view"
require_relative "protostar/builder"
require_relative "protostar/compiler"
require_relative "protostar/schema/proto"
require_relative "protostar/dsl"
require_relative "protostar/compiler/emitters"
