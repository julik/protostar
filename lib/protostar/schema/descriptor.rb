# frozen_string_literal: true

module Protostar
  module Schema
    # What every descriptor has. Built only by {Builder}, frozen and shareable afterwards.
    class Descriptor
      # @return [String] the simple name
      attr_reader :name
      # @return [String] the fully qualified name, without a leading dot
      attr_reader :full_name
      # @return [Integer] position among its siblings, in declaration order
      attr_reader :index
      # @return [Features] resolved features
      attr_reader :features

      # @return [Options] declared options; once resolved, also the resolved {Options#features}
      def options
        @options || Options::UNRESOLVED.fetch(self.class)
      end

      # Sets attributes that only become known while linking. The Builder is the
      # only caller; everything is frozen once it is done.
      # @api private
      def __link(**attrs)
        attrs.each { |key, value| instance_variable_set(:"@#{key}", value) }
        self
      end

      def inspect
        "#<#{self.class.name} #{full_name}>"
      end
      alias_method :to_s, :inspect

      private

      def options_to_h(h)
        h[:options] = @options.__legacy_h if @options&.declared?
        h
      end
    end
  end
end
