# frozen_string_literal: true

# Random instances of Protostar message classes for property tests: every
# field kind, edge values, bounded nesting, oneofs, maps, open enum numbers
# without a name, and unknown fields of every wire type injected.
#
#   RandomMessage.build(klass, random: Random.new(1), depth: 3)
module RandomMessage
  F = Protostar::Message::FieldInfo

  INT32 = [0, 1, -1, 127, 128, 300, -300, 2**31 - 1, -2**31].freeze
  INT64 = [0, 1, -1, 2**31, 2**32 - 1, 2**53, 2**63 - 1, -2**63].freeze
  UINT32 = [0, 1, 127, 128, 16_383, 16_384, 2**31, 2**32 - 1].freeze
  UINT64 = [0, 1, 2**32, 2**56, 2**63, 2**64 - 1].freeze
  DOUBLES = [0.0, -0.0, 1.5, -2.25, 1e300, -1e-300, 5e-324, Float::INFINITY, -Float::INFINITY, Float::NAN].freeze
  FLOATS = [0.0, -0.0, 1.5, -2.25, 3.4028234663852886e+38, 1.401298464324817e-45, Float::INFINITY, Float::NAN].freeze
  CHARS = ["a", "z", "0", " ", "é", "ß", "日", "本", "😀", "\u0000", "\u007f", "\u0080", "߿", "ࠀ", "￿"].freeze
  RANGES = Protostar::Message::Coercion::RANGES

  module_function

  # @param klass [Class] a Protostar message class
  # @param random [Random]
  # @param depth [Integer] message nesting allowed below this one
  # @param fill [Float] chance that each field is set
  # @param unknown [Boolean] whether to inject unknown fields
  # @return [Protostar::Message]
  def build(klass, random:, depth: 3, fill: 0.5, unknown: true)
    msg = klass.new
    chosen = {}
    klass.descriptor.real_oneofs.each do |o|
      chosen[o] = o.fields.sample(random: random) if random.rand < fill
    end
    klass.__fields.each do |info|
      field = info.descriptor
      if (oneof = field.real_oneof)
        next unless chosen[oneof].equal?(field)
      elsif random.rand >= fill
        next
      end
      value = field_value(info, random, depth, fill, unknown)
      msg.__set(info.index, value) unless value.nil?
    end
    inject_unknown(msg, random) if unknown
    msg
  end

  def field_value(info, random, depth, fill, unknown)
    if info.map
      return nil if info.value.message? && depth <= 0
      Array.new(random.rand(4)) do
        [scalar(info.key, random), single(info.value, random, depth, fill, unknown)]
      end.to_h
    elsif info.repeated
      return nil if info.message? && depth <= 0
      Array.new(random.rand(1..4)) { single(info, random, depth, fill, unknown) }
    else
      return nil if info.message? && depth <= 0
      single(info, random, depth, fill, unknown)
    end
  end

  def single(info, random, depth, fill, unknown)
    return build(info.message_class, random: random, depth: depth - 1, fill: fill, unknown: unknown) if info.message?
    scalar(info, random)
  end

  def scalar(info, random)
    case info.kind
    when F::INT32, F::SINT32, F::SFIXED32 then pick(INT32, random) { random.rand(RANGES.fetch(info.kind)) }
    when F::INT64, F::SINT64, F::SFIXED64 then pick(INT64, random) { random.rand(RANGES.fetch(info.kind)) }
    when F::UINT32, F::FIXED32 then pick(UINT32, random) { random.rand(2**32) }
    when F::UINT64, F::FIXED64 then pick(UINT64, random) { random.rand(2**64) }
    when F::DOUBLE then pick(DOUBLES, random) { (random.rand - 0.5) * 10**random.rand(-30..30) }
    when F::FLOAT then [pick(FLOATS, random) { (random.rand - 0.5) * 10**random.rand(-10..10) }].pack("e").unpack1("e")
    when F::BOOL then random.rand(2) == 1
    when F::STRING then Array.new(random.rand(8)) { CHARS.sample(random: random) }.join
    when F::BYTES then random.bytes(random.rand(10))
    when F::ENUM then enum_value(info, random)
    end
  end

  def enum_value(info, random)
    if !info.closed_enum && random.rand < 0.2
      n = random.rand(-5..1000)
      return n unless info.enum_names.key?(n)
    end
    info.enum_names.values.sample(random: random)
  end

  def pick(edges, random)
    (random.rand < 0.5) ? edges.sample(random: random) : yield
  end

  # Adds a few unknown fields at numbers the message does not use
  def inject_unknown(msg, random)
    desc = msg.class.descriptor
    return if desc.message_set_wire_format? || desc.map_entry?
    top = desc.fields.map(&:number).max || 0
    random.rand(3).times do
      number = top + 1 + random.rand(1000)
      next if desc.fields_by_number.key?(number) || desc.extension_number?(number)
      next if number > Protostar::Wire::MAX_FIELD_NUMBER || (19_000..19_999).cover?(number)
      msg.__add_unknown(unknown_field(number, random))
    end
    msg.__seal_unknown
  end

  def unknown_field(number, random)
    w = Protostar::Wire::Writer.new
    wire_type = [0, 1, 2, 3, 5].sample(random: random)
    case wire_type
    when 0 then w.write_varint(random.rand(2**64))
    when 1 then w.write_fixed64(random.rand(2**64))
    when 2 then w.write_bytes(random.bytes(random.rand(6)))
    when 3
      w.write_tag(1, 0).write_varint(random.rand(1000))
      w.write_tag(2, 2).write_bytes("in a group")
      w.write_tag(number, 4)
    when 5 then w.write_fixed32(random.rand(2**32))
    end
    Protostar::UnknownField.new(number, wire_type, w.string)
  end
end
