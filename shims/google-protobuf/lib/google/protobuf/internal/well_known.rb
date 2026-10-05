# frozen_string_literal: true

module Google
  module Protobuf
    module Internal
      # The Ruby helpers of google.protobuf.Struct, Value and ListValue as
      # the gem's well_known_types.rb defines them. {MessageClass.setup}
      # includes them after {MessageMethods}, so their `[]`, `[]=` and `to_h`
      # win over the message methods of the same names, whether or not
      # well_known_types is required.
      # @api private
      module WellKnown
        module Value
          module ClassMethods
            # @return [Value] a new Value holding the Ruby value
            def from_ruby(value)
              new.from_ruby(value)
            end
          end

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

          # Sets the kind matching a Ruby value
          # @return [self]
          # @raise [UnexpectedStructType]
          def from_ruby(value)
            by_name = self.class.__by_name
            struct = by_name.fetch("struct_value").message_class
            list = by_name.fetch("list_value").message_class
            case value
            when NilClass then self.null_value = :NULL_VALUE
            when Numeric then self.number_value = value
            when String then self.string_value = value
            when TrueClass then self.bool_value = true
            when FalseClass then self.bool_value = false
            when struct then self.struct_value = value
            when Hash then self.struct_value = struct.from_hash(value)
            when list then self.list_value = value
            when Array then self.list_value = list.from_a(value)
            else raise UnexpectedStructType
            end
            self
          end
        end

        module Struct
          module ClassMethods
            # @return [Struct]
            def from_hash(hash)
              struct = new
              hash.each { |key, value| struct[key] = value }
              struct
            end
          end

          # @return [Object, nil] the value as Ruby; nil for a missing key
          def [](key)
            fields[key].to_ruby
          rescue NoMethodError
            nil
          end

          # @raise [UnexpectedStructType] for a key that is not a String or a value Struct cannot hold
          def []=(key, value)
            raise UnexpectedStructType, "Struct keys must be strings." unless key.is_a?(String)
            fields[key] ||= self.class.__by_name.fetch("fields").value.message_class.new
            fields[key].from_ruby(value)
          end

          # @return [Hash] with nested Structs and ListValues converted too
          def to_h
            fields.each_with_object({}) { |(key, value), h| h[key] = value.to_ruby(true) }
          end

          def has_key?(key)
            fields.has_key?(key)
          end
        end

        module ListValue
          include Enumerable

          module ClassMethods
            # @return [ListValue]
            def from_a(array)
              list = new
              array.each { |v| list << v }
              list
            end
          end

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
            values << self.class.__by_name.fetch("values").message_class.new.from_ruby(value)
          end

          def each
            values.each { |v| yield v.to_ruby }
          end

          # @return [Array] with nested Structs and ListValues converted too
          def to_a
            values.map { |v| v.to_ruby(true) }
          end
        end

        # Full name to the module {MessageClass.setup} mixes in
        MIXINS = {
          "google.protobuf.Struct" => Struct,
          "google.protobuf.Value" => Value,
          "google.protobuf.ListValue" => ListValue
        }.freeze
      end
    end
  end
end
