# frozen_string_literal: true

require "forwardable"

module Google
  module Protobuf
    # An Array-like list of values of one type, checked on every write. A
    # message's repeated field reads as a RepeatedField over the message's
    # own storage, so writes to it are writes to the message.
    class RepeatedField
      include Enumerable
      extend Forwardable

      # @overload new(type, initial_values = [])
      # @overload new(type, type_class, initial_values = [])
      #   @param type_class [Class, Module] a message class or enum module, for :message and :enum
      # @param type [Symbol] :int32, :string, :message, :enum and so on
      def self.new(*args)
        raise ArgumentError, "Expected at least 1 argument." if args.empty?
        type, *rest = args
        sub, initial = Internal.type_class(type, rest)
        unless initial.nil? || initial.is_a?(Array)
          raise ArgumentError, "Expected array as initializer value for repeated field 'RepeatedField' (given #{initial.class})."
        end
        instance = allocate
        instance.__setup(type, sub, [], "")
        initial&.each { |v| instance.push(v) }
        instance
      end

      # @api private
      def self.__for_field(fd, array)
        instance = allocate
        instance.__setup(fd.type, fd.subtype, array, fd.name)
        instance
      end

      # @api private
      def __setup(type, sub, array, name)
        @type = type
        @sub = sub
        @array = array
        @name = name
      end

      # @api private
      def __array
        @array
      end

      # @api private
      def __type
        @type
      end

      # @api private
      def __sub
        @sub
      end

      # @api private
      # @raise [TypeError] unless this list can be the field's value
      def __check_field(fd)
        unless FieldDescriptor::CTYPES.fetch(@type) == fd.__ctype
          raise TypeError, "Repeated field array has wrong element type"
        end
        raise TypeError, "Repeated field array has wrong message/enum class" unless @sub.equal?(fd.subtype)
      end

      def each(&block)
        return enum_for(:each) { size } unless block
        @array.each(&block)
        self
      end

      # @overload [](index)
      # @overload [](start, length)
      # @overload [](range)
      def [](*args)
        if args.size == 1 && args[0].is_a?(Integer)
          @array[args[0]]
        else
          @array[*args]
        end
      end
      alias_method :at, :[]
      alias_method :slice, :[]

      # Sets the element at the index, filling any gap with zero values
      def []=(index, value)
        check_frozen
        count = @array.size
        index += count if index < 0
        return nil if index < 0
        v = convert(value)
        if index >= count
          zero = Internal::Convert.zero(@type, @sub)
          @array.fill(zero, count, index - count) if index > count
        end
        @array[index] = v
        nil
      end

      # @return [self]
      def push(*values)
        check_frozen
        converted = values.map { |v| convert(v) }
        @array.concat(converted)
        self
      end

      # @return [self]
      def <<(value)
        check_frozen
        @array << convert(value)
        self
      end

      # @return [self]
      def replace(list)
        check_frozen
        converted = list.to_a.map { |v| convert(v) }
        @array.replace(converted)
        self
      end

      # @return [self]
      def clear
        check_frozen
        @array.clear
        self
      end

      def length
        @array.length
      end
      alias_method :size, :length

      def empty?
        @array.empty?
      end

      def first(n = nil)
        return @array.first if n.nil?
        raise ArgumentError, "negative array size" if n < 0
        @array.first(n)
      end

      def last(n = nil)
        return @array.last if n.nil?
        raise ArgumentError, "negative array size" if n < 0
        @array.last(n)
      end

      def pop(n = nil)
        if n
          results = []
          n.times { results << pop_one }
          results
        else
          pop_one
        end
      end

      # @return [Array] a copy of the elements
      def to_ary
        @array.dup
      end
      alias_method :to_a, :to_ary

      # Equal to a RepeatedField of the same type and elements, or an Array of the same elements
      def ==(other)
        return true if equal?(other)
        case other
        when RepeatedField
          FieldDescriptor::CTYPES.fetch(@type) == FieldDescriptor::CTYPES.fetch(other.__type) &&
            @sub.equal?(other.__sub) && @array == other.__array
        when Array then @array == other
        else false
        end
      end

      def hash
        @array.hash
      end

      # @return [RepeatedField] a new list of the same elements; messages are shared
      def dup
        copy = self.class.allocate
        copy.__setup(@type, @sub, @array.dup, @name)
        copy
      end
      alias_method :clone, :dup

      # @api private
      def __deep_copy
        copy = self.class.allocate
        copy.__setup(@type, @sub, @array.map { |v| Internal.deep_copy_value(v) }, @name)
        copy
      end

      # @return [RepeatedField] a new list of this one's elements followed by the other's
      def +(other)
        case other
        when RepeatedField
          unless @type == other.__type && @sub.equal?(other.__sub)
            raise ArgumentError, "Attempt to append RepeatedField with different element type."
          end
          copy = dup
          copy.__array.concat(other.__array)
          copy
        when Enumerable
          dup.push(*other.to_a)
        else
          raise ArgumentError, "Unknown type appending to RepeatedField"
        end
      end

      # Appends every element of the Array
      # @return [self]
      def concat(other)
        raise ArgumentError, "Expected Enumerable, but got #{other.class}" unless other.is_a?(Enumerable)
        push(*other.to_a)
      end

      def frozen?
        super || @array.frozen?
      end

      # Freezes the list, its storage and the messages in it
      def freeze
        return self if super_frozen?
        unless @array.frozen?
          @array.each { |v| v.freeze if v.is_a?(Protostar::Message) }
          @array.freeze
        end
        super
      end

      def inspect
        @array.inspect
      end

      def_delegators :to_ary,
        :&, :*, :-, :<=>,
        :assoc, :bsearch, :bsearch_index, :combination, :compact, :count,
        :cycle, :difference, :dig, :drop, :drop_while, :eql?, :fetch, :find_index, :flatten,
        :include?, :index, :intersection, :join,
        :pack, :permutation, :product, :pretty_print, :pretty_print_cycle,
        :rassoc, :repeated_combination, :repeated_permutation, :reverse,
        :rindex, :rotate, :sample, :shuffle, :shelljoin,
        :to_s, :transpose, :union, :uniq, :|

      alias_method :values_at, :select
      alias_method :map, :collect

      # Array methods that change the list: run on a copy, then written back
      # through #replace so that every element is checked
      class << self
        private

        def define_array_wrapper_method(method_name)
          define_method(method_name) do |*args, &block|
            arr = to_a
            result = arr.send(method_name, *args)
            replace(arr)
            return result if result
            block ? block.call : result
          end
        end

        def define_array_wrapper_with_result_method(method_name)
          define_method(method_name) do |*args, &block|
            result = to_a.send(method_name, *args, &block)
            if result
              new_arr = result.to_a
              replace(new_arr)
              if result.is_a?(Enumerator)
                result = ProxyingEnumerator.new(self, new_arr.to_enum).to_enum
              end
            end
            result
          end
        end
      end

      %w[delete delete_at shift slice! unshift].each { |m| define_array_wrapper_method(m) }

      %w[collect! compact! delete_if each_index fill flatten! insert reverse!
        rotate! select! shuffle! sort! sort_by! uniq!].each { |m| define_array_wrapper_with_result_method(m) }
      alias_method :keep_if, :select!
      alias_method :map!, :collect!
      alias_method :reject!, :delete_if

      # Writes changes made through an Enumerator from #sort! and the like back to the list
      # @api private
      class ProxyingEnumerator
        def initialize(repeated_field, external_enumerator)
          @repeated_field = repeated_field
          @external_enumerator = external_enumerator
        end

        def each(*)
          results = []
          @external_enumerator.each_with_index do |val, i|
            result = yield(val)
            results << result
            @repeated_field[i] = result if result && result != val
          end
          results
        end
      end

      private

      def convert(value)
        Internal::Convert.to_store(value, @type, @sub, @name)
      end

      def pop_one
        check_frozen
        @array.pop
      end

      def check_frozen
        raise FrozenError.new("can't modify frozen #{self.class}", receiver: self) if frozen?
      end

      def super_frozen?
        Object.instance_method(:frozen?).bind_call(self)
      end
    end

    module Internal
      # The element type of a RepeatedField or the value type of a Map from
      # the arguments after the type: the class or module for :message and
      # :enum, then the initial values
      # @api private
      # @return [Array(Descriptor, EnumDescriptor, nil), Object]
      def self.type_class(type, rest)
        raise ArgumentError, "Expected symbol for field type." unless type.is_a?(Symbol)
        raise ArgumentError, "Unknown field type." unless FieldDescriptor::CTYPES.key?(type)
        return [nil, rest[0]] unless type == :message || type == :enum || type == :group
        raise ArgumentError, "Expected at least 2 arguments for message/enum." if rest.empty?
        klass = rest[0]
        descriptor = klass.respond_to?(:descriptor) ? klass.descriptor : nil
        expected = (type == :enum) ? EnumDescriptor : Descriptor
        unless descriptor.is_a?(expected)
          raise ArgumentError, "Type class #{klass} has no descriptor. Please pass a class or enum as returned by the DescriptorPool."
        end
        [descriptor, rest[1]]
      end
    end
  end
end
