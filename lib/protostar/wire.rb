# frozen_string_literal: true

module Protostar
  # The protobuf binary wire format: wire types, tags, varints, zigzag, and a
  # Reader and Writer over byte strings that the codec and later layers
  # (JSON, streaming builders) share.
  module Wire
    VARINT = 0
    FIXED64 = 1
    LENGTH_DELIMITED = 2
    START_GROUP = 3
    END_GROUP = 4
    FIXED32 = 5

    # Wire type numbers to names, for messages
    NAMES = {
      VARINT => :varint, FIXED64 => :fixed64, LENGTH_DELIMITED => :length_delimited,
      START_GROUP => :start_group, END_GROUP => :end_group, FIXED32 => :fixed32
    }.freeze

    MAX_FIELD_NUMBER = 536_870_911
    MASK32 = 0xFFFF_FFFF
    MASK64 = 0xFFFF_FFFF_FFFF_FFFF

    BINARY = Encoding::BINARY

    # - `number`: field number
    #
    # Returns the tag value as written on the wire, before varint encoding.
    #: (Integer number, Integer wire_type) -> Integer
    def self.tag(number, wire_type)
      (number << 3) | wire_type
    end

    # Returns a frozen binary String holding the varint-encoded tag.
    #: (untyped number, untyped wire_type) -> String
    def self.tag_bytes(number, wire_type)
      varint(tag(number, wire_type))
    end

    # - `value`: negative values are written as their 64-bit two's complement
    #
    # Returns a frozen binary String.
    #: (Integer value) -> String
    def self.varint(value)
      Writer.new.write_varint(value).string.freeze
    end

    # Appends a varint to a binary String and returns it. Negative values are
    # written as their 64-bit two's complement.
    #: (String buf, Integer value) -> String
    def self.append_varint(buf, value)
      value &= MASK64 if value < 0
      while value >= 0x80
        buf << ((value & 0x7F) | 0x80)
        value >>= 7
      end
      buf << value
    end

    # Returns how many bytes `varint` would take; 10 for any negative value.
    #: (untyped value) -> Integer
    def self.varint_size(value)
      if value < 0 then 10
      elsif value < 0x80 then 1
      elsif value < 0x4000 then 2
      elsif value < 0x20_0000 then 3
      elsif value < 0x1000_0000 then 4
      elsif value < 0x8_0000_0000 then 5
      elsif value < 0x400_0000_0000 then 6
      elsif value < 0x2_0000_0000_0000 then 7
      elsif value < 0x100_0000_0000_0000 then 8
      elsif value < 0x8000_0000_0000_0000 then 9
      else 10
      end
    end

    # - `value`: a signed 64-bit (or 32-bit) integer
    #
    # Returns the unsigned zigzag form.
    #: (Integer value) -> Integer
    def self.zigzag(value)
      (value << 1) ^ (value >> 63)
    end

    # - `value`: an unsigned zigzag-encoded integer
    #
    # Returns the signed integer it encodes.
    #: (Integer value) -> Integer
    def self.unzigzag(value)
      (value >> 1) ^ -(value & 1)
    end

    # The four little-endian bytes of a NaN as a float, the way C converts a
    # double NaN to float: sign and the top 23 bits of the payload kept, quiet
    # bit set. `pack("e")` instead writes the same NaN whatever the value.
    #
    # - `nan`: a NaN
    #
    # Returns a binary String.
    #: (Float nan) -> String
    def self.float_nan(nan)
      bits = [nan].pack("E").unpack1("Q<")
      [((bits >> 32) & 0x8000_0000) | 0x7FC0_0000 | ((bits >> 29) & 0x7F_FFFF)].pack("V")
    end

    # A run of floats as packed bytes, NaNs written by `float_nan`
    #
    # Returns a binary String.
    #: ((Array[(Float | Integer)]) list) -> String
    def self.pack_floats(list)
      bytes = list.pack("e*")
      list.each_with_index { |v, i| bytes[4 * i, 4] = float_nan(v) if v.is_a?(Float) && v.nan? }
      bytes
    end
  end
end

require_relative "wire/io_source"
require_relative "wire/reader"
require_relative "wire/writer"
