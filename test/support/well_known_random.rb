# frozen_string_literal: true

# Makes random messages from RandomMessage valid for JSON: every well-known
# type inside gets contents that have a JSON form (a Timestamp in range, an
# Any holding a message its registry knows, a Value with a kind set, ...).
#
#   WellKnownRandom.sanitize(message, random: Random.new(1), registry: set.registry)
module WellKnownRandom
  TIMESTAMP_RANGE = -62_135_596_800..253_402_300_799
  DURATION_MAX = 315_576_000_000
  NANOS = [0, 1, 1000, 1_000_000, 500_000_000, 999_999_999].freeze
  PATHS = ["foo", "foo_bar", "a.b_c.d", "x1", "deeply.nested_field.leaf_name"].freeze
  # Types an Any is given to hold, when the registry has them
  ANY_TYPES = %w[
    google.protobuf.Duration google.protobuf.Timestamp google.protobuf.Int32Value google.protobuf.StringValue
    google.protobuf.Empty google.protobuf.Struct google.protobuf.FieldMask google.protobuf.Any
    protobuf_test_messages.proto3.TestAllTypesProto3 proto3_unittest.TestAllTypes proto2_unittest.TestMap
  ].freeze
  LEAF_TYPES = %w[google.protobuf.Duration google.protobuf.Int32Value google.protobuf.Empty].freeze

  module_function

  def sanitize(msg, random:, registry:, depth: 2)
    msg.class.__fields.each do |info|
      v = msg.__values[info.index]
      next if v.nil?
      if null_value?(info) || (info.map && null_value?(info.value))
        value = if info.map then v.transform_values { :NULL_VALUE }
        elsif info.repeated then v.map { :NULL_VALUE }
        else :NULL_VALUE
        end
        msg.__set(info.index, value)
      elsif info.map
        next unless info.value.message?
        v.each_value { |m| sanitize(m, random: random, registry: registry, depth: depth) }
      elsif info.message?
        (v.is_a?(Array) ? v : [v]).each { |m| sanitize(m, random: random, registry: registry, depth: depth) }
      end
    end
    fix(msg, random, registry, depth)
    msg
  end

  # NullValue has one name; JSON can only say null, so other numbers cannot round-trip
  def null_value?(info)
    info.kind == Protostar::Message::FieldInfo::ENUM && info.enum_module.descriptor.full_name == "google.protobuf.NullValue"
  end

  # The bytes inside an Any are compared as they are, and a JSON round trip
  # through google-protobuf may reorder map entries; one entry keeps the order
  def single_entry_maps(msg)
    msg.class.__fields.each do |info|
      v = msg.__values[info.index]
      next if v.nil?
      if info.map
        msg.__set(info.index, v.first(1).to_h)
        v.each_value { |m| single_entry_maps(m) } if info.value.message?
      elsif info.message?
        (v.is_a?(Array) ? v : [v]).each { |m| single_entry_maps(m) }
      end
    end
  end

  def set(msg, name, value)
    msg.__set(msg.class.__by_name.fetch(name).index, value)
  end

  def fix(msg, random, registry, depth)
    case msg.class.descriptor.full_name
    when "google.protobuf.Timestamp"
      set(msg, "seconds", random.rand(TIMESTAMP_RANGE))
      set(msg, "nanos", (random.rand < 0.5) ? NANOS.sample(random: random) : random.rand(1_000_000_000))
    when "google.protobuf.Duration"
      seconds = random.rand(-DURATION_MAX..DURATION_MAX)
      seconds = 0 if random.rand < 0.2
      nanos = (random.rand < 0.5) ? NANOS.sample(random: random) : random.rand(1_000_000_000)
      nanos = -nanos if seconds < 0 || (seconds == 0 && random.rand < 0.5)
      set(msg, "seconds", seconds)
      set(msg, "nanos", nanos)
    when "google.protobuf.FieldMask"
      set(msg, "paths", Array.new(random.rand(4)) { PATHS.sample(random: random) })
    when "google.protobuf.Value"
      kind = msg.which_kind
      if kind.nil?
        set(msg, "null_value", :NULL_VALUE)
      elsif kind == :number_value && !msg.number_value.finite?
        set(msg, "number_value", 1.5)
      end
    when "google.protobuf.Any"
      names = ((depth > 0) ? ANY_TYPES : LEAF_TYPES).select { |n| registry.find(n).is_a?(Class) }
      raise ArgumentError, "no type for an Any to hold" if names.empty?
      klass = registry.find(names.sample(random: random))
      inner = RandomMessage.build(klass, random: random, depth: [depth - 1, 0].max, fill: 0.3, unknown: false)
      sanitize(inner, random: random, registry: registry, depth: depth - 1)
      single_entry_maps(inner)
      prefix = ["type.googleapis.com/", "example.com/types/", "x/"].sample(random: random)
      set(msg, "type_url", prefix + klass.descriptor.full_name)
      set(msg, "value", inner.encode)
    end
  end
end
