# frozen_string_literal: true

module Protostar
  # A field the decoder did not recognise, kept so that it is re-emitted on
  # encode. {#bytes} are the raw bytes that followed the tag on the wire,
  # verbatim: a varint as it was encoded, 4 or 8 fixed bytes, a length prefix
  # and its payload, or a group's contents through its end tag.
  class UnknownField
    # @return [Integer]
    attr_reader :number
    # @return [Integer] one of the {Wire} wire type constants
    attr_reader :wire_type
    # @return [String] frozen, binary
    attr_reader :bytes

    # @param number [Integer]
    # @param wire_type [Integer]
    # @param bytes [String] the bytes after the tag; copied unless frozen and binary
    def initialize(number, wire_type, bytes)
      @number = number
      @wire_type = wire_type
      @bytes = (bytes.frozen? && bytes.encoding == Encoding::BINARY) ? bytes : bytes.b.freeze
      freeze
    end

    # @return [Integer, String] the decoded value: an Integer for varint and
    #   fixed wire types, the payload without its length prefix for
    #   length-delimited, the contents without the end tag for a group
    def value
      r = Wire::Reader.new(@bytes)
      case @wire_type
      when Wire::VARINT then r.read_varint
      when Wire::FIXED32 then r.read_fixed32
      when Wire::FIXED64 then r.read_fixed64
      when Wire::LENGTH_DELIMITED then r.read_bytes
      else @bytes.byteslice(0, @bytes.bytesize - Wire.varint_size(Wire.tag(@number, Wire::END_GROUP)))
      end
    end

    # @return [String] the field as it goes on the wire, tag included
    def to_wire
      Wire.tag_bytes(@number, @wire_type) + @bytes
    end

    def ==(other)
      other.is_a?(UnknownField) && other.number == @number && other.wire_type == @wire_type && other.bytes == @bytes
    end
    alias_method :eql?, :==

    def hash
      [UnknownField, @number, @wire_type, @bytes].hash
    end

    def inspect
      "#<#{self.class.name} #{@number}:#{Wire::NAMES.fetch(@wire_type)} #{@bytes.inspect}>"
    end
  end
end
