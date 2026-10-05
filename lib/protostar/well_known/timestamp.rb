# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.Timestamp
    module Timestamp
      def self.included(base)
        base.extend(ClassMethods)
      end

      # @param value [Object]
      # @return [Array(Integer, Integer), nil] seconds and nanos of a Time, a
      #   DateTime or a Date; nil for anything else
      def self.parts(value)
        time = if value.is_a?(::Time) then value
        elsif defined?(::Date) && value.is_a?(::Date) then value.to_time
        else return nil
        end
        [time.to_i, time.nsec]
      end

      module ClassMethods
        # @param time [Time]
        # @return [Message] a new Timestamp at the same instant, to the nanosecond
        def from_time(time)
          new.from_time(time)
        end

        # What a Timestamp field makes of a value that is neither a Timestamp
        # nor a Hash: a Time, a DateTime or a Date becomes a Timestamp
        # @return [Message, nil]
        # @api private
        def __coerce(value)
          seconds, nanos = Timestamp.parts(value)
          new(seconds: seconds, nanos: nanos) if seconds
        end
      end

      # @param time [Time]
      # @return [self]
      def from_time(time)
        self.seconds = time.to_i
        self.nanos = time.nsec
        self
      end

      # @return [Time] in the local zone, as `Time.at` gives it
      def to_time
        ::Time.at(seconds, nanos, :nanosecond)
      end

      # @return [Integer] seconds since the epoch
      def to_i
        seconds
      end

      # @return [Rational] seconds since the epoch, exact; google-protobuf
      #   returns a Rational here too
      def to_f
        seconds + nanos.quo(1_000_000_000)
      end
    end
  end
end
