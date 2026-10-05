# frozen_string_literal: true

module Google
  module Protobuf
    # Included into every message class. Libraries extend it (and
    # {ClassMethods}) to give all messages more methods, as with the gem.
    module MessageExts
      def self.included(klass)
        klass.extend(ClassMethods)
      end

      # Extended by every message class
      module ClassMethods
      end

      # @param options [Hash] see the class's encode_json
      # @return [String]
      def to_json(options = {})
        self.class.encode_json(self, options)
      end

      # @param options [Hash] see the class's encode
      # @return [String] binary
      def to_proto(options = {})
        self.class.encode(self, options)
      end

      def to_hash
        to_h
      end
    end

    # What the gem's message classes inherit from. Classes here inherit from
    # Protostar::Message instead and include MessageExts directly.
    class AbstractMessage
      include MessageExts
      extend MessageExts::ClassMethods
    end
    private_constant :AbstractMessage
  end
end
