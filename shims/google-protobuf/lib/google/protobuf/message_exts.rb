# frozen_string_literal: true

module Google
  module Protobuf
    # Included into every message class. Libraries extend it (and
    # ClassMethods) to give all messages more methods, as with the gem.
    module MessageExts
      def self.included(klass)
        klass.extend(ClassMethods)
      end

      # Extended by every message class
      module ClassMethods
      end

      # - `options`: see the class's encode_json
      #: (?Hash[untyped, untyped] options) -> String
      def to_json(options = {})
        self.class.encode_json(self, options)
      end

      # - `options`: see the class's encode
      #
      # Returns binary.
      #: (?Hash[untyped, untyped] options) -> String
      def to_proto(options = {})
        self.class.encode(self, options)
      end

      def to_hash
        to_h
      end
    end

    # What every message class inherits from, as in the gem, where tools
    # such as tapioca look for its descendants. Private there too.
    class AbstractMessage < Protostar::Message
      include MessageExts
    end
    private_constant :AbstractMessage
  end
end
