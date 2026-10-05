# frozen_string_literal: true

module Protostar
  # Raised for malformed wire input. {#offset} is the byte position in the
  # decoded buffer where the problem was found.
  class DecodeError < Error
    # @return [Integer, nil]
    attr_reader :offset

    def initialize(message, offset: nil)
      @offset = offset
      super(offset ? "#{message} at byte #{offset}" : message)
    end
  end

  # Raised when encoding a message whose stored values cannot be written
  class EncodeError < Error; end

  # Raised when a value of the wrong type, out of range or with invalid
  # contents is assigned to a field. A subclass of Ruby's TypeError so that
  # callers used to google-protobuf's errors can rescue it the same way.
  class TypeError < ::TypeError; end
end
