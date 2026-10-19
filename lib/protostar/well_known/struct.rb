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
        # Returns a new Struct.
        # Raises UnexpectedStructType.
        #: (Hash[String, untyped] hash) -> Google::Protobuf::Struct
        def from_hash(hash)
          struct = new
          hash.each { |key, value| struct[key] = value }
          struct
        end

        def __value_class # :nodoc:
          __by_name.fetch("fields").value.message_class
        end
      end

      # Returns the value as Ruby, Structs and ListValues
      # left as they are; nil for a missing key.
      #: (String key) -> untyped
      def [](key)
        fields[key]&.to_ruby
      end

      # Raises UnexpectedStructType for a key that is not a String or a value Struct cannot hold.
      #: (String key, untyped value) -> untyped
      def []=(key, value)
        raise UnexpectedStructType, "Struct keys must be strings." unless key.is_a?(String)
        (fields[key] ||= self.class.__value_class.new).from_ruby(value)
      end

      # Returns a Hash with nested Structs and ListValues
      # converted too.
      #: () -> Hash[String, untyped]
      def to_h
        fields.transform_values { |v| v.to_ruby(true) }
      end

      #: (String key) -> bool
      def has_key?(key)
        fields.key?(key)
      end
    end
  end
end
