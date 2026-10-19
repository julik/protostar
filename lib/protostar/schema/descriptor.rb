# frozen_string_literal: true

module Protostar
  module Schema
    # What every descriptor has. Made by a Draft, frozen and shareable once it is finished.
    class Descriptor
      # The simple name.
      attr_reader :name #: String
      # The fully qualified name, without a leading dot.
      attr_reader :full_name #: String
      # Position among its siblings, in declaration order.
      attr_reader :index #: Integer
      # Resolved features.
      attr_reader :features #: Features

      # Returns declared options; once resolved, also the resolved Options#features.
      #: () -> untyped
      def options
        @options || Options::UNRESOLVED.fetch(self.class)
      end

      # Sets attributes that only become known while linking. Drafts are the
      # callers; everything is frozen once the draft is finished.
      def __link(**attrs) # :nodoc:
        attrs.each { |key, value| instance_variable_set(:"@#{key}", value) }
        self
      end

      def inspect
        "#<#{self.class.name} #{full_name}>"
      end
      alias_method :to_s, :inspect

      # `to_proto` as a Hash, for reading; nothing builds from it
      #: () -> Hash[Symbol, untyped]
      def to_h
        to_proto.to_h
      end
    end
  end
end
