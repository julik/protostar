# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.Duration
    module Duration
      # Duration's range in seconds, about 10,000 years
      MAX_SECONDS = 315_576_000_000
      NANOS = 1_000_000_000

      def self.included(base)
        base.extend(ClassMethods)
      end

      # Splits a number of seconds into whole seconds and nanoseconds of the
      # same sign, rounding to the nearest nanosecond
      # @param value [Object]
      # @return [Array(Integer, Integer), nil] nil when the value is not a Numeric
      # @raise [FloatDomainError] for NaN and Infinity
      # @raise [RangeError] beyond {MAX_SECONDS}
      def self.parts(value)
        return nil unless value.is_a?(Numeric)
        r = value.to_r
        seconds = r.truncate
        nanos = ((r - seconds) * NANOS).round
        if nanos.abs >= NANOS
          seconds += nanos <=> 0
          nanos -= (nanos <=> 0) * NANOS
        end
        raise RangeError, "#{value.inspect} is out of Duration's range" if seconds.abs > MAX_SECONDS
        [seconds, nanos]
      end

      module ClassMethods
        # What a Duration field makes of a value that is neither a Duration
        # nor a Hash: a Numeric of seconds (Integer, Float, Rational) becomes
        # a Duration
        # @return [Message, nil]
        # @raise [RangeError] for NaN, Infinity, or beyond Duration's range
        # @api private
        def __coerce(value)
          seconds, nanos = Duration.parts(value)
          new(seconds: seconds, nanos: nanos) if seconds
        end
      end

      # @return [Float] seconds
      def to_f
        seconds + nanos.to_f / 1_000_000_000
      end
    end
  end
end
