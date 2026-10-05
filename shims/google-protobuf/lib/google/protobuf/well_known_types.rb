# frozen_string_literal: true

require "google/protobuf/any_pb"
require "google/protobuf/duration_pb"
require "google/protobuf/field_mask_pb"
require "google/protobuf/struct_pb"
require "google/protobuf/timestamp_pb"

# Any (pack, unpack, is, type_name), Timestamp (from_time, to_time, to_i,
# to_f) and Duration (to_f) have their helpers from Protostar::WellKnown,
# which protostar mixes into those classes however they are defined. Struct,
# Value and ListValue are defined here: their [], []= and to_h replace the
# message methods of the same names, and they raise the gem's errors.
module Google
  module Protobuf
    Value.class_eval do
      # @param recursive [Boolean] convert a Struct or ListValue to a Hash or Array as well
      # @return [Object]
      # @raise [UnexpectedStructType] when no kind is set
      def to_ruby(recursive = false)
        case kind
        when :struct_value then recursive ? struct_value.to_h : struct_value
        when :list_value then recursive ? list_value.to_a : list_value
        when :null_value then nil
        when :number_value then number_value
        when :string_value then string_value
        when :bool_value then bool_value
        else raise UnexpectedStructType
        end
      end

      # @return [Value] a new Value holding the Ruby value
      def self.from_ruby(value)
        new.from_ruby(value)
      end

      # Sets the kind matching a Ruby value
      # @return [self]
      # @raise [UnexpectedStructType]
      def from_ruby(value)
        case value
        when NilClass then self.null_value = :NULL_VALUE
        when Numeric then self.number_value = value
        when String then self.string_value = value
        when TrueClass then self.bool_value = true
        when FalseClass then self.bool_value = false
        when Struct then self.struct_value = value
        when Hash then self.struct_value = Struct.from_hash(value)
        when ListValue then self.list_value = value
        when Array then self.list_value = ListValue.from_a(value)
        else raise UnexpectedStructType
        end
        self
      end
    end

    Struct.class_eval do
      # @return [Object, nil] the value as Ruby; nil for a missing key
      def [](key)
        fields[key].to_ruby
      rescue NoMethodError
        nil
      end

      # @raise [UnexpectedStructType] for a key that is not a String or a value Struct cannot hold
      def []=(key, value)
        raise UnexpectedStructType, "Struct keys must be strings." unless key.is_a?(String)
        fields[key] ||= Value.new
        fields[key].from_ruby(value)
      end

      # @return [Hash] with nested Structs and ListValues converted too
      def to_h
        fields.each_with_object({}) { |(key, value), h| h[key] = value.to_ruby(true) }
      end

      # @return [Struct]
      def self.from_hash(hash)
        struct = new
        hash.each { |key, value| struct[key] = value }
        struct
      end

      def has_key?(key)
        fields.has_key?(key)
      end
    end

    ListValue.class_eval do
      include Enumerable

      def length
        values.length
      end

      def [](index)
        values[index].to_ruby
      end

      def []=(index, value)
        values[index].from_ruby(value)
      end

      def <<(value)
        values << Value.new.from_ruby(value)
      end

      def each
        values.each { |v| yield v.to_ruby }
      end

      # @return [Array] with nested Structs and ListValues converted too
      def to_a
        values.map { |v| v.to_ruby(true) }
      end

      # @return [ListValue]
      def self.from_a(array)
        list = new
        array.each { |v| list << v }
        list
      end
    end
  end
end
