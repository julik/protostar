# frozen_string_literal: true

module Protostar
  class View
    # The value of a map field read through a view. The entries are read on
    # first use, keys and scalar values decoded; message values stay
    # positions until read, then become nested views. A key that occurs
    # twice keeps the last entry, as decoding does.
    #
    #   view.attrs["colour"]
    #   view.attrs.key?("size")
    #   view.attrs.to_h
    class Map
      include Enumerable

      F = Message::FieldInfo
      private_constant :F

      # Reads one map entry
      # @return [Array(Object, Object, Boolean)] key, value and whether the
      #   value is a closed enum's unknown number. A message value is the
      #   flat Array of its segments' offsets and lengths.
      # @api private
      def self.entry(buf, offset, length, info, depth)
        c = Cursor.new(buf, offset + length)
        c.pos = offset
        key_info = info.key
        value_info = info.value
        key = nil
        value = nil
        unknown_enum = false
        while c.pos < c.limit
          at = c.pos
          tag = c.read_varint
          Wire::Reader.check_tag(tag, at)
          number = tag >> 3
          wt = tag & 7
          if number == 1 && wt == key_info.wire_type
            key = Codec::Decoder.scalar(c, key_info)
          elsif number == 2 && wt == value_info.wire_type
            if value_info.message?
              n = c.read_varint
              start = c.pos
              c.skip(n)
              value = [] unless value.is_a?(Array)
              value << start << n
            elsif value_info.kind == F::ENUM
              n = c.read_int32
              value = value_info.enum_names[n]
              if value.nil?
                unknown_enum = value_info.closed_enum
                value = n
              else
                unknown_enum = false
              end
            else
              value = Codec::Decoder.scalar(c, value_info)
            end
          else
            raise DecodeError.new("unmatched end of group #{number}", offset: at) if wt == Wire::END_GROUP
            c.skip_field(number, wt, depth)
          end
        end
        key = key_info.default if key.nil?
        if value.nil?
          value = value_info.message? ? [] : value_info.default
        end
        [key, value, unknown_enum]
      end

      # @api private
      def initialize(buf, info, entries, depth)
        @buf = buf
        @info = info
        @entries = entries
        @depth = depth
        @memo = [info ? nil : Message::EMPTY_HASH]
        freeze
      end

      # @return [Object, nil] the value for `key`, nil when there is none
      def [](key)
        h = __hash
        v = h[key]
        v.is_a?(Array) ? (h[key] = Scan.nested(@info.value, @buf, v, @depth)) : v
      end

      # @raise [KeyError] when there is no such key
      def fetch(key, *default, &block)
        return self[key] if __hash.key?(key)
        __hash.fetch(key, *default, &block)
      end

      def key?(key)
        __hash.key?(key)
      end
      alias_method :has_key?, :key?
      alias_method :include?, :key?
      alias_method :member?, :key?

      # @return [Array]
      def keys
        __hash.keys
      end

      # @return [Array]
      def values
        to_h.values
      end

      # @return [Integer]
      def size
        __hash.size
      end
      alias_method :length, :size

      def empty?
        __hash.empty?
      end

      # Yields each key and value, in the order the keys first occurred
      def each(&block)
        return enum_for(:each) { size } unless block
        to_h.each(&block)
        self
      end
      alias_method :each_pair, :each

      # @return [Hash] every key and value, message values as nested views; frozen
      def to_h
        h = __hash
        return h if h.frozen?
        __resolve
        h.dup.freeze
      end

      # Equal to another Map or a Hash with equal keys and values
      def ==(other)
        case other
        when Map, Hash then to_h == other.to_h
        else false
        end
      end

      def hash
        to_h.hash
      end

      def inspect
        to_h.inspect
      end

      # Decodes every entry and freezes what it keeps, after which the
      # container is Ractor-shareable when its buffer is
      # @return [self]
      def freeze_index
        return self if @memo.frozen?
        __resolve.each_value { |v| v.freeze_index if v.is_a?(View) }
        @memo[0].freeze
        @entries.freeze
        @memo.freeze
        self
      end

      # @api private
      def __hash
        @memo[0] ||= begin
          h = {}
          entries = @entries
          k = 0
          while k < entries.size
            key, value, unknown_enum = Map.entry(@buf, entries[k], entries[k + 1], @info, @depth)
            h[key] = value unless unknown_enum
            k += 2
          end
          h
        end
      end

      private

      def __resolve
        h = __hash
        h.each_key { |key| self[key] }
        h
      end

      EMPTY = new(nil, nil, [].freeze, 0).freeze_index
    end
  end
end
