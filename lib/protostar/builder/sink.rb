# frozen_string_literal: true

module Protostar
  class Builder
    # The writer a builder streams into. What the sink raises is raised
    # again with the field being written added to its message, keeping its
    # class: a broken pipe stays an Errno::EPIPE.
    # @api private
    class Sink < Wire::Writer
      def initialize(target, flush_at, builder)
        super(target, flush_at: flush_at)
        @builder = builder
      end

      # @return [Exception] `e` again, its message saying where the builder was
      def annotate(e)
        e.exception("#{e.message} (while writing #{@builder.__send__(:__where)})")
      end

      private

      def deliver(bytes)
        super
      rescue => e
        raise annotate(e)
      end

      def deliver_all(*chunks)
        super
      rescue => e
        raise annotate(e)
      end
    end
  end
end
