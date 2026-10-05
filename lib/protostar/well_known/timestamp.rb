# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.Timestamp
    module Timestamp
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # @param time [Time]
        # @return [Message] a new Timestamp at the same instant, to the nanosecond
        def from_time(time)
          new.from_time(time)
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
