# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.ListValue: an Array of plain Ruby values
    module ListValue
      include Enumerable #[untyped]

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Returns a new ListValue.
        # Raises UnexpectedStructType.
        #: (Array[untyped] array) -> Google::Protobuf::ListValue
        def from_a(array)
          list = new
          array.each { |v| list << v }
          list
        end

        def __value_class # :nodoc:
          __by_name.fetch("values").message_class
        end
      end

      #: () -> Integer
      def length
        values.length
      end

      # Returns the element as Ruby, Structs and ListValues left as they are.
      #: (Integer index) -> untyped
      def [](index)
        values[index].to_ruby
      end

      #: (Integer index, untyped value) -> untyped
      def []=(index, value)
        values[index].from_ruby(value)
      end

      # Appends a Ruby value
      #: (untyped value) -> self
      def <<(value)
        values << self.class.__value_class.new.from_ruby(value)
        self
      end

      # Yields each element as Ruby, Structs and ListValues left as they are
      #: () { (untyped) -> void } -> self
      #: () -> Enumerator[untyped, self]
      def each
        return enum_for(:each) { length } unless block_given?
        values.each { |v| yield v.to_ruby }
        self
      end

      # Returns an Array with nested Structs and ListValues converted too.
      #: () -> Array[untyped]
      def to_a
        values.map { |v| v.to_ruby(true) }
      end
    end
  end
end
