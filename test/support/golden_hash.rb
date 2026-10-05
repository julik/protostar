# frozen_string_literal: true

require "json"

# Converts a golden `.json` (protoc's FileDescriptorSet in the proto3 JSON
# mapping) into descriptor hashes shaped like `FileDescriptorProto#to_h`:
# proto field names as Symbol keys, enum values as Symbols, 64-bit integers as
# Integers, bytes as binary Strings.
#
# The shape of descriptor.proto is read from descriptor.proto's own golden,
# whose type metadata (field names, types, enum values) needs no conversion.
module GoldenHash
  INT64_TYPES = %w[TYPE_INT64 TYPE_UINT64 TYPE_SINT64 TYPE_FIXED64 TYPE_SFIXED64].freeze
  FLOAT_SPECIALS = {"Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY, "NaN" => Float::NAN}.freeze

  # One field of a descriptor.proto message
  Field = Struct.new(:name, :type, :type_name, :repeated)

  # @param path [String] a golden .json
  # @return [Array<Hash>] one FileDescriptorProto hash per file, in protoc's
  #   order (dependencies before dependents)
  def self.load(path)
    convert(JSON.parse(File.read(path)), "google.protobuf.FileDescriptorSet").fetch(:file)
  end

  # @param json [Object] parsed JSON for a message of the given descriptor.proto type
  # @param type [String] full name of a descriptor.proto message, no leading dot
  def self.convert(json, type)
    fields = schema.fetch(:messages).fetch(type)
    json.to_h do |key, value|
      field = fields.fetch(key) { raise ArgumentError, "#{type} has no JSON field #{key.inspect}" }
      converted = field.repeated ? value.map { |v| scalar(v, field) } : scalar(value, field)
      [field.name, converted]
    end
  end

  def self.scalar(value, field)
    case field.type
    when "TYPE_MESSAGE", "TYPE_GROUP" then convert(value, field.type_name)
    when "TYPE_ENUM"
      return value.to_sym if value.is_a?(String)
      # protoc's JSON printer writes a number for a value its descriptor.proto lacked
      schema.fetch(:enums).fetch(field.type_name).fetch(value, value)
    when *INT64_TYPES then Integer(value)
    when "TYPE_BYTES" then value.unpack1("m").b
    when "TYPE_DOUBLE", "TYPE_FLOAT" then FLOAT_SPECIALS.fetch(value) { Float(value) }
    else value
    end
  end

  def self.schema
    @schema ||= begin
      set = JSON.parse(File.read(Corpus.golden("google/protobuf/descriptor.proto", :json)))
      file = set.fetch("file").find { |f| f["name"] == "google/protobuf/descriptor.proto" }
      messages = {}
      enums = {}
      walk = lambda do |msg, scope|
        full = "#{scope}.#{msg["name"]}"
        messages[full] = msg.fetch("field", []).to_h do |f|
          type_name = f["typeName"]&.delete_prefix(".")
          [f.fetch("jsonName"), Field.new(f["name"].to_sym, f["type"], type_name, f["label"] == "LABEL_REPEATED")]
        end
        msg.fetch("enumType", []).each { |e| enums["#{full}.#{e["name"]}"] = enum_values(e) }
        msg.fetch("nestedType", []).each { |n| walk.call(n, full) }
      end
      file.fetch("messageType").each { |m| walk.call(m, file["package"]) }
      file.fetch("enumType").each { |e| enums["#{file["package"]}.#{e["name"]}"] = enum_values(e) }
      {messages: messages, enums: enums}.freeze
    end
  end

  def self.enum_values(enum)
    enum.fetch("value").each_with_object({}) { |v, out| out[v["number"]] ||= v["name"].to_sym }
  end
end
