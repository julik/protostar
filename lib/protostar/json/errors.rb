# frozen_string_literal: true

module Protostar
  module JSON
    # Raised by everything in {JSON}
    class Error < Protostar::Error; end

    # Raised for JSON that does not describe a message of the class it is
    # decoded into. {#path} names the field where the problem was found, as
    # in `friends[2].name`; it is empty for the top-level value.
    class ParseError < Error
      # @return [String]
      attr_reader :path

      def initialize(message, path = "")
        @path = path
        super(path.empty? ? message : "#{path}: #{message}")
      end
    end

    # Raised for a message whose contents have no JSON form: a Timestamp or
    # Duration out of range, an Any whose type cannot be found, a Value with
    # no kind set and the like
    class EncodeError < Error
      # @return [String]
      attr_reader :path

      def initialize(message, path = "")
        @path = path
        super(path.empty? ? message : "#{path}: #{message}")
      end
    end
  end
end
