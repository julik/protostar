# frozen_string_literal: true

require_relative "protostar/version"

# Protocol buffers in pure Ruby: a `.proto` compiler ({Compiler}), message
# classes with a binary codec, views, JSON and the text format, and the
# {DSL} that generated `_pb.rb` files are written in. README.md has the tour.
#
# `require "protostar"` loads the schema, the wire format and the binary
# codec. The rest is autoloaded on first use: in a program that uses
# Ractors, touch what a Ractor will need in the main Ractor first, since
# Ruby 3.2 and 3.3 cannot load files from any other.
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

  autoload :Types, File.expand_path("protostar/types", __dir__)
  autoload :DSL, File.expand_path("protostar/dsl", __dir__)
  autoload :WellKnown, File.expand_path("protostar/well_known", __dir__)
  autoload :JSON, File.expand_path("protostar/json", __dir__)
  autoload :Text, File.expand_path("protostar/text", __dir__)
  autoload :View, File.expand_path("protostar/view", __dir__)
  autoload :Builder, File.expand_path("protostar/builder", __dir__)
  autoload :Compiler, File.expand_path("protostar/compiler", __dir__)
  autoload :Diagnostics, File.expand_path("protostar/diagnostics", __dir__)
  autoload :CLI, File.expand_path("protostar/cli", __dir__)
  autoload :Plugin, File.expand_path("protostar/plugin", __dir__)

  # The message classes and enums of the `.proto` files protostar ships
  # generated (`Compiler::Emitters::BOOTSTRAP`), each loading its `_pb.rb`
  # file on first use
  module Google
    module Protobuf
      {
        "any" => %i[Any],
        "api" => %i[Api Method Mixin],
        "compiler/plugin" => %i[Compiler],
        "descriptor" => %i[
          FileDescriptorSet FileDescriptorProto DescriptorProto ExtensionRangeOptions FieldDescriptorProto
          OneofDescriptorProto EnumDescriptorProto EnumValueDescriptorProto ServiceDescriptorProto
          MethodDescriptorProto FileOptions MessageOptions FieldOptions OneofOptions EnumOptions EnumValueOptions
          ServiceOptions MethodOptions UninterpretedOption FeatureSet FeatureSetDefaults SourceCodeInfo
          GeneratedCodeInfo Edition SymbolVisibility
        ],
        "duration" => %i[Duration],
        "empty" => %i[Empty],
        "field_mask" => %i[FieldMask],
        "source_context" => %i[SourceContext],
        "struct" => %i[Struct Value ListValue NullValue],
        "timestamp" => %i[Timestamp],
        "type" => %i[Type Field Enum EnumValue Option Syntax],
        "wrappers" => %i[DoubleValue FloatValue Int64Value UInt64Value Int32Value UInt32Value BoolValue StringValue BytesValue]
      }.each do |file, names|
        path = ::File.expand_path("protostar/google/protobuf/#{file}_pb", __dir__)
        names.each { |name| autoload(name, path) }
      end
    end
  end

  # Short names for the well-known types: `Protostar::Timestamp` is
  # `Protostar::Google::Protobuf::Timestamp`
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
