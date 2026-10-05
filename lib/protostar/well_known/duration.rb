# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.Duration
    module Duration
      # @return [Float] seconds
      def to_f
        seconds + nanos.to_f / 1_000_000_000
      end
    end
  end
end
