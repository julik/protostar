# frozen_string_literal: true

module Protostar
  # The protobuf binary wire format: wire types, tags, varints, zigzag, and a
  # {Reader} and {Writer} over byte strings that the codec and later layers
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

    # @param number [Integer] field number
    # @param wire_type [Integer]
    # @return [Integer] the tag value as written on the wire, before varint encoding
    def self.tag(number, wire_type)
      (number << 3) | wire_type
    end

    # @return [String] a frozen binary String holding the varint-encoded tag
    def self.tag_bytes(number, wire_type)
      varint(tag(number, wire_type))
    end

    # @param value [Integer] negative values are written as their 64-bit two's complement
    # @return [String] a frozen binary String
    def self.varint(value)
      Writer.new.write_varint(value).string.freeze
    end

    # @return [Integer] how many bytes {varint} would take; 10 for any negative value
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

    # @param value [Integer] a signed 64-bit (or 32-bit) integer
    # @return [Integer] the unsigned zigzag form
    def self.zigzag(value)
      (value << 1) ^ (value >> 63)
    end

    # @param value [Integer] an unsigned zigzag-encoded integer
    # @return [Integer] the signed integer it encodes
    def self.unzigzag(value)
      (value >> 1) ^ -(value & 1)
    end

    # The four little-endian bytes of a NaN as a float, the way C converts a
    # double NaN to float: sign and the top 23 bits of the payload kept, quiet
    # bit set. `pack("e")` instead writes the same NaN whatever the value.
    # @param nan [Float] a NaN
    # @return [String] binary
    def self.float_nan(nan)
      bits = [nan].pack("E").unpack1("Q<")
      [((bits >> 32) & 0x8000_0000) | 0x7FC0_0000 | ((bits >> 29) & 0x7F_FFFF)].pack("V")
    end

    # A run of floats as packed bytes, NaNs written by {float_nan}
    # @param list [Array<Float, Integer>]
    # @return [String] binary
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
