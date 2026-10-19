# frozen_string_literal: true

module Protostar
  class View
    # The value of a repeated field read through a view. Elements of string,
    # bytes and message fields are decoded one at a time when first read
    # (messages as nested views over the same buffer); numbers, booleans and
    # enums are decoded all together on first use. Every decoded element is
    # kept, so reading it again is free.
    #
    # ```ruby
    # view.friends.size
    # view.friends[2].name
    # view.lucky_numbers.to_a # => [7, 13]
    # ```
    class Repeated
      include Enumerable #[untyped]

      FieldInfo = Message::FieldInfo
      private_constant :FieldInfo

      def initialize(buf, info, entries, depth) # :nodoc:
        @buf = buf
        @info = info
        @entries = entries
        @depth = depth
        @lazy = info ? (info.message? || info.kind == FieldInfo::STRING || info.kind == FieldInfo::BYTES) : false
        @memo = if @lazy
          Array.new(entries.size / 2)
        else
          [info ? nil : Message::EMPTY_ARRAY]
        end
        freeze
      end

      #: () -> Integer
      def size
        @lazy ? @memo.size : __values.size
      end
      alias_method :length, :size

      def empty?
        size.zero?
      end

      # The element at `index` (negative counts from the end), nil when out of
      # range; with a length or a Range, an Array as Array#[] returns it.
      #: (Integer index) -> untyped
      #: (Integer start, Integer length) -> Array[untyped]?
      #: (Range[Integer?] range) -> Array[untyped]?
      def [](index, length = nil)
        return to_a[index, length] if length
        return to_a[index] unless index.is_a?(Integer)
        return __values[index] unless @lazy
        size = @memo.size
        index += size if index < 0
        return nil if index < 0 || index >= size
        __element(index)
      end

      def each(&block)
        return enum_for(:each) { size } unless block
        if @lazy
          @memo.size.times { |j| yield __element(j) }
        else
          __values.each(&block)
        end
        self
      end

      # Returns the elements; frozen.
      #: () -> Array[untyped]
      def to_a
        return __values unless @lazy
        Array.new(@memo.size) { |j| __element(j) }.freeze
      end
      alias_method :to_ary, :to_a

      # Equal to another Repeated or an Array with equal elements
      def ==(other)
        case other
        when Repeated, Array then to_a == other.to_a
        else false
        end
      end

      def hash
        to_a.hash
      end

      def inspect
        to_a.inspect
      end

      def pretty_print(q)
        q.pp(to_a)
      end

      # Decodes every element and freezes what it keeps, after which the
      # container is Ractor-shareable when its buffer is
      #: () -> self
      def freeze_index
        return self if @memo.frozen?
        if @lazy
          @memo.size.times do |j|
            e = __element(j)
            e.freeze_index if e.is_a?(View)
          end
        else
          __values
        end
        @entries.freeze
        @memo.freeze
        self
      end

      def __values # :nodoc:
        @memo[0] ||= Scan.scalars(@buf, @info, @entries)
      end

      private

      def __element(j)
        memo = @memo
        v = memo[j]
        return v unless v.nil?
        offset = @entries[2 * j]
        length = @entries[2 * j + 1]
        info = @info
        memo[j] = case info.kind
        when FieldInfo::STRING then Scan.string(@buf, offset, length, info)
        when FieldInfo::BYTES then Scan.bytes(@buf, offset, length)
        else
          raise DecodeError.new("recursion limit exceeded", offset: offset) if @depth <= 0
          info.message_class.__view_class.__new(@buf, offset, length, nil, @depth - 1)
        end
      end

      EMPTY = new(nil, nil, [].freeze, 0).freeze_index
    end
  end
end
