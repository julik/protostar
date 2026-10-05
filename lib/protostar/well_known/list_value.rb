# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.ListValue: an Array of plain Ruby values
    module ListValue
      include Enumerable

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # @param array [Array]
        # @return [Message] a new ListValue
        # @raise [UnexpectedStructType]
        def from_a(array)
          list = new
          array.each { |v| list << v }
          list
        end

        # @api private
        def __value_class
          __by_name.fetch("values").message_class
        end
      end

      # @return [Integer]
      def length
        values.length
      end

      # @return [Object] the element as Ruby, Structs and ListValues left as they are
      def [](index)
        values[index].to_ruby
      end

      def []=(index, value)
        values[index].from_ruby(value)
      end

      # Appends a Ruby value
      # @return [self]
      def <<(value)
        values << self.class.__value_class.new.from_ruby(value)
        self
      end

      # Yields each element as Ruby, Structs and ListValues left as they are
      def each
        return enum_for(:each) { length } unless block_given?
        values.each { |v| yield v.to_ruby }
        self
      end

      # @return [Array] with nested Structs and ListValues converted too
      def to_a
        values.map { |v| v.to_ruby(true) }
      end
    end
  end
end
