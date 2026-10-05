# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.Struct: a Hash of String keys to plain Ruby
    # values (nil, Numeric, String, true, false, Hash, Array)
    module Struct
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # @param hash [Hash{String => Object}]
        # @return [Message] a new Struct
        # @raise [UnexpectedStructType]
        def from_hash(hash)
          struct = new
          hash.each { |key, value| struct[key] = value }
          struct
        end

        # @api private
        def __value_class
          __by_name.fetch("fields").value.message_class
        end
      end

      # @param key [String]
      # @return [Object, nil] the value as Ruby, Structs and ListValues
      #   left as they are; nil for a missing key
      def [](key)
        fields[key]&.to_ruby
      end

      # @param key [String]
      # @param value [Object]
      # @raise [UnexpectedStructType] for a key that is not a String or a value Struct cannot hold
      def []=(key, value)
        raise UnexpectedStructType, "Struct keys must be strings." unless key.is_a?(String)
        (fields[key] ||= self.class.__value_class.new).from_ruby(value)
      end

      # @return [Hash{String => Object}] with nested Structs and ListValues
      #   converted too
      def to_h
        fields.transform_values { |v| v.to_ruby(true) }
      end

      # @param key [String]
      def has_key?(key)
        fields.key?(key)
      end
    end
  end
end
