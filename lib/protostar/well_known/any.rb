# frozen_string_literal: true

module Protostar
  module WellKnown
    # Mixed into google.protobuf.Any
    module Any
      DEFAULT_PREFIX = "type.googleapis.com/"

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Returns a new Any holding the message.
        #: (Message message, ?String type_url_prefix) -> Google::Protobuf::Any
        def pack(message, type_url_prefix = DEFAULT_PREFIX)
          new.pack(message, type_url_prefix)
        end
      end

      # Stores the message's bytes and a type URL of the prefix and its full
      # name; a `/` is put between them when the prefix lacks one
      #: (Message message, ?String type_url_prefix) -> self
      def pack(message, type_url_prefix = DEFAULT_PREFIX)
        name = message.class.descriptor.full_name
        self.type_url = type_url_prefix.end_with?("/") ? "#{type_url_prefix}#{name}" : "#{type_url_prefix}/#{name}"
        self.value = message.encode
        self
      end

      # - `klass`: the message class expected inside
      #
      # Returns the decoded message, or nil when the Any holds another type.
      #: (singleton(Message) klass) -> Message?
      def unpack(klass)
        klass.decode(value) if is(klass)
      end

      # Returns the full name at the end of the type URL.
      #: () -> String
      def type_name
        type_url.split("/")[-1]
      end

      # Returns whether the Any holds a message of that class.
      #: (singleton(Message) klass) -> bool
      def is(klass)
        type_name == klass.descriptor.full_name
      end
    end
  end
end
