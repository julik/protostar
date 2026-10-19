# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.Timestamp
    module Timestamp
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Returns seconds and nanos of a Time, a
      # DateTime or a Date; nil for anything else.
      #: (untyped value) -> [ Integer, Integer ]?
      def self.parts(value)
        time = if value.is_a?(::Time) then value
        elsif defined?(::Date) && value.is_a?(::Date) then value.to_time
        else return nil
        end
        [time.to_i, time.nsec]
      end

      module ClassMethods
        # Returns a new Timestamp at the same instant, to the nanosecond.
        #: (Time time) -> Google::Protobuf::Timestamp
        def from_time(time)
          new.from_time(time)
        end

        # What a Timestamp field makes of a value that is neither a Timestamp
        # nor a Hash: a Time, a DateTime or a Date becomes a Timestamp
        #: (untyped value) -> Message?
        def __coerce(value) # :nodoc:
          seconds, nanos = Timestamp.parts(value)
          new(seconds: seconds, nanos: nanos) if seconds
        end
      end

      #: (Time time) -> self
      def from_time(time)
        self.seconds = time.to_i
        self.nanos = time.nsec
        self
      end

      # Returns a Time in the local zone, as `Time.at` gives it.
      #: () -> Time
      def to_time
        ::Time.at(seconds, nanos, :nanosecond)
      end

      # Returns seconds since the epoch.
      #: () -> Integer
      def to_i
        seconds
      end

      # Returns seconds since the epoch, exact; google-protobuf
      # returns a Rational here too.
      #: () -> Rational
      def to_f
        seconds + nanos.quo(1_000_000_000)
      end
    end
  end
end
