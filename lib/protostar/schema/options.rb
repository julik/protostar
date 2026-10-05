# frozen_string_literal: true

module Protostar
  module Schema
    # The options of a descriptor as an immutable wrapper over the options hash:
    # known fields of the options message under their proto names, custom options
    # under `:__extensions` (keyed by extension full name) and uninterpretable
    # bytes under `:__unknown_fields` as `[number, wire_type, bytes]` triples.
    class Options
      # @api private
      # @param spec [Hash, Options, nil]
      # @return [Options, nil]
      def self.build(spec)
        case spec
        when nil, Options then spec
        when Hash then new(Freezer.call(spec))
        else raise Error, "options must be a Hash, got #{spec.class}"
        end
      end

      # @param hash [Hash] a frozen options hash
      def initialize(hash)
        @hash = hash
      end

      # @param key [Symbol] a field name of the options message
      # @return [Object, nil]
      def [](key)
        @hash[key]
      end

      # Same as Hash#fetch on the options hash
      def fetch(key, *default, &block)
        @hash.fetch(key, *default, &block)
      end

      # @return [Boolean] whether the option was set
      def key?(key)
        @hash.key?(key)
      end

      # @return [Hash] the options hash, including `:__extensions` and `:__unknown_fields`
      def to_h
        @hash
      end

      # @return [Hash{String => Object}] custom option values by extension full name
      def extensions
        @hash.fetch(:__extensions, Freezer::EMPTY_HASH)
      end

      # @return [Array<Array(Integer, Integer, String)>] option bytes nobody could interpret
      def unknown_fields
        @hash.fetch(:__unknown_fields, Freezer::EMPTY_ARRAY)
      end

      # @return [Boolean]
      def empty?
        @hash.empty?
      end

      # @return [Hash, nil] the raw, unresolved `features` option
      def features
        @hash[:features]
      end

      def ==(other)
        other.is_a?(Options) && other.to_h == @hash
      end
      alias_method :eql?, :==

      def hash
        @hash.hash
      end

      def inspect
        "#<#{self.class.name} #{@hash.inspect}>"
      end

      # Returned by descriptors that declared no options. One that declared an
      # empty options message holds its own empty instance instead, which is how
      # `to_h` tells the two apart and reproduces `options: {}`.
      EMPTY = new(Freezer::EMPTY_HASH).freeze
    end
  end
end
