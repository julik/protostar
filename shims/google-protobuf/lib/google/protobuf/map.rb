# frozen_string_literal: true

module Google
  module Protobuf
    # A Hash-like map with keys and values of fixed types, checked on every
    # write. A message's map field reads as a Map over the message's own
    # storage, so writes to it are writes to the message.
    class Map
      include Enumerable

      KEY_TYPES = %i[int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes]
        .to_h { |t| [t, true] }.freeze
      private_constant :KEY_TYPES

      # @overload new(key_type, value_type, init_hashmap = {})
      # @overload new(key_type, value_type, value_typeclass, init_hashmap = {})
      #   @param value_typeclass [Class, Module] for :message and :enum values
      # @param key_type [Symbol]
      # @param value_type [Symbol]
      def self.new(*args)
        raise ArgumentError, "Map constructor expects 2, 3 or 4 arguments." if args.size < 2 || args.size > 4
        key_type, value_type, *rest = args
        raise ArgumentError, "Expected symbol for field type." unless key_type.is_a?(Symbol)
        raise ArgumentError, "Unknown field type." unless Internal::CONTAINER_TYPES.key?(key_type)
        sub, initial = Internal.type_class(value_type, rest, 1)
        raise ArgumentError, "Invalid key type for map." unless KEY_TYPES.key?(key_type)
        instance = allocate
        instance.__setup(key_type, value_type, sub, {}, "")
        instance.__merge_into_self(initial) unless initial.nil?
        instance
      end

      # @api private
      def self.__for_field(fd, hash)
        entry = fd.subtype
        key = entry.lookup("key")
        value = entry.lookup("value")
        instance = allocate
        instance.__setup(key.type, value.type, value.subtype, hash, "")
        instance
      end

      # @api private
      def __setup(key_type, value_type, sub, hash, name)
        @key_type = key_type
        @value_type = value_type
        @sub = sub
        @hash = hash
        @name = name
      end

      # @api private
      def __hash
        @hash
      end
      alias_method :__storage, :__hash

      # @api private
      def __types
        [FieldDescriptor::CTYPES.fetch(@key_type), FieldDescriptor::CTYPES.fetch(@value_type), @sub]
      end

      # @api private
      # @raise [TypeError] unless this map can be the field's value
      def __check_field(fd)
        entry = fd.subtype
        key = entry.lookup("key")
        value = entry.lookup("value")
        raise TypeError, "Map key type does not match field's key type" unless FieldDescriptor::CTYPES.fetch(@key_type) == key.__ctype
        raise TypeError, "Map value type does not match field's value type" unless FieldDescriptor::CTYPES.fetch(@value_type) == value.__ctype
        raise TypeError, "Map value type has wrong message/enum class" unless @sub.equal?(value.subtype)
      end

      # @return [Object, nil] the value, nil when the key is not there
      def [](key)
        @hash[convert_key(key)]
      end

      # @return [Object] the value given
      def []=(key, value)
        check_frozen
        k = convert_key(key)
        @hash[k] = convert_value(value)
        value
      end

      def has_key?(key)
        @hash.key?(convert_key(key))
      end

      # @return [Object, nil] the value removed
      def delete(key)
        check_frozen
        @hash.delete(convert_key(key))
      end

      # @return [nil]
      def clear
        check_frozen
        @hash.clear
        nil
      end

      def length
        @hash.length
      end
      alias_method :size, :length

      def keys
        @hash.keys
      end

      def values
        @hash.values
      end

      # Yields each key and value
      # @return [nil]
      def each(&block)
        return enum_for(:each) { size } unless block
        @hash.each(&block)
        nil
      end

      # @return [Hash] with message values as Hashes
      def to_h
        return @hash.dup unless @value_type == :message || @value_type == :group
        @hash.transform_values(&:to_h)
      end

      def inspect
        "{#{@hash.map { |k, v| "#{k.inspect}=>#{v.inspect}" }.join(", ")}}"
      end

      # Equal to a Map of the same types and entries, or a Hash with those entries
      def ==(other)
        return true if equal?(other)
        if other.is_a?(Hash)
          hash = other
          other = Map.allocate
          other.__setup(@key_type, @value_type, @sub, {}, @name)
          other.__merge_into_self(hash)
        end
        return false unless other.is_a?(Map)
        __types == other.__types && @hash == other.__hash
      end

      def hash
        h = 0
        @hash.each { |k, v| h += [k, v].hash }
        h
      end

      # @return [Map] a copy; message values are shared
      def dup
        copy = Map.allocate
        copy.__setup(@key_type, @value_type, @sub, @hash.dup, @name)
        copy
      end
      alias_method :clone, :dup

      # @api private
      def __deep_copy
        copy = Map.allocate
        copy.__setup(@key_type, @value_type, @sub, @hash.transform_values { |v| Internal.deep_copy_value(v) }, @name)
        copy
      end

      # @param other [Map, Hash]
      # @return [Map] a copy of this map with the other's entries written over it
      def merge(other)
        dup.__merge_into_self(other)
      end

      # @api private
      def __merge_into_self(other)
        case other
        when Hash
          other.each { |k, v| @hash[convert_key(k)] = convert_value(v) }
        when Map
          raise ArgumentError, "Attempt to merge Map with mismatching types" unless __types == other.__types
          @hash.merge!(other.__hash)
        else
          raise ArgumentError, "Unknown type merging into Map"
        end
        self
      end

      def frozen?
        super || @hash.frozen?
      end

      # Freezes the map, its storage and the messages in it
      def freeze
        return self if Object.instance_method(:frozen?).bind_call(self)
        unless @hash.frozen?
          @hash.each_value { |v| v.freeze if v.is_a?(Protostar::Message) }
          @hash.freeze
        end
        super
      end

      private

      def convert_key(key)
        Internal::Convert.to_store(key, @key_type, nil, @name)
      end

      def convert_value(value)
        Internal::Convert.to_store(value, @value_type, @sub, @name)
      end

      def check_frozen
        raise FrozenError.new("can't modify frozen #{self.class}: #{inspect}", receiver: self) if frozen?
      end
    end
  end
end
