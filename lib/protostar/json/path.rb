# frozen_string_literal: true

module Protostar
  module JSON
    # Where the encoder or parser is in a message, kept as a stack of field
    # names, Integer indexes and map keys, turned into text only for errors
    module Path # :nodoc: all
      # A map key on the stack, printed as `[key]`
      class MapKey
        attr_reader :key #: untyped

        def initialize(key)
          @key = key
          freeze
        end
      end

      module_function

      # Returns a name such as `friends[2].name` or `labels["x"]`.
      #: ((Array[(String | Integer | MapKey)]) stack) -> String
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
