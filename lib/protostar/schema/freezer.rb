# frozen_string_literal: true

module Protostar
  module Schema
    # Deep-copies plain data (Hashes, Arrays, Strings, scalars) into frozen,
    # deduplicated form so that building never freezes the caller's input.
    # @api private
    module Freezer
      EMPTY_HASH = {}.freeze
      EMPTY_ARRAY = [].freeze

      def self.call(value)
        case value
        when Hash
          return EMPTY_HASH if value.empty?
          value.each_with_object({}) { |(k, v), out| out[call(k)] = call(v) }.freeze
        when Array
          return EMPTY_ARRAY if value.empty?
          value.map { |v| call(v) }.freeze
        when String
          -value
        when Symbol, Integer, Float, true, false, nil
          value
        else
          raise Error, "cannot store a #{value.class} in a descriptor: #{value.inspect}"
        end
      end
    end
  end
end
