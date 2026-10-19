# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.Value
    module Value
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # - `value`: nil, Numeric, String, true, false, Hash,
        #   Array, a Struct or a ListValue
        #
        # Returns a new Value.
        # Raises UnexpectedStructType.
        #: (untyped value) -> Google::Protobuf::Value
        def from_ruby(value)
          new.from_ruby(value)
        end
      end

      # - `recursive`: whether to convert a Struct or ListValue to
      #   a Hash or Array as well
      #
      # Raises UnexpectedStructType when no kind is set.
      #: (?bool recursive) -> untyped
      def to_ruby(recursive = false)
        case which_kind
        when :struct_value then recursive ? struct_value.to_h : struct_value
        when :list_value then recursive ? list_value.to_a : list_value
        when :null_value then nil
        when :number_value then number_value
        when :string_value then string_value
        when :bool_value then bool_value
        else raise UnexpectedStructType
        end
      end

      # Sets the kind matching a Ruby value
      #
      # Raises UnexpectedStructType.
      #: (untyped value) -> self
      def from_ruby(value)
        fields = self.class.__by_name
        struct_class = fields.fetch("struct_value").message_class
        list_class = fields.fetch("list_value").message_class
        case value
        when NilClass then self.null_value = :NULL_VALUE
        when Numeric then self.number_value = value.to_f
        when String then self.string_value = value
        when TrueClass then self.bool_value = true
        when FalseClass then self.bool_value = false
        when struct_class then self.struct_value = value
        when Hash then self.struct_value = struct_class.from_hash(value)
        when list_class then self.list_value = value
        when Array then self.list_value = list_class.from_a(value)
        else raise UnexpectedStructType
        end
        self
      end
    end
  end
end
