# frozen_string_literal: true

module Protostar
  module JSON
    # Where the encoder or parser is in a message, kept as a stack of field
    # names, Integer indexes and map keys, turned into text only for errors
    # @api private
    module Path
      MapKey = ::Struct.new(:key)

      module_function

      # @param stack [Array<String, Integer, MapKey>]
      # @return [String] e.g. `friends[2].name` or `labels["x"]`
      def to_s(stack)
        out = +""
        stack.each do |seg|
          case seg
          when Integer then out << "[#{seg}]"
          when MapKey then out << "[#{seg.key.inspect}]"
          else
            out << "." unless out.empty?
            out << seg
          end
        end
        out
      end
    end
  end
end
