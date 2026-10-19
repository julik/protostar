# frozen_string_literal: true

module Protostar
  module Lint
    # Case conversions as buf's naming rules apply them
    module Naming
      module_function

      # Returns the words of a name in any case: "HTTPServer_v2" is HTTP, Server, v2.
      #: (untyped name) -> Array[String]
      def words(name)
        name.split(/_+/).flat_map { |part| part.scan(/[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+[a-z]*|[A-Z]+/) }
          .reject(&:empty?)
      end

      # Returns "fooBar" as "foo_bar".
      #: (untyped name) -> String
      def lower_snake(name)
        joined(name).downcase
      end

      # Returns "fooBar" as "FOO_BAR".
      #: (untyped name) -> String
      def upper_snake(name)
        joined(name).upcase
      end

      # Returns "foo_bar" as "FooBar".
      #: (untyped name) -> String
      def pascal(name)
        words(name).map { |w| w[0].upcase + w[1..] }.join
      end

      def lower_snake?(name)
        name.match?(/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/)
      end

      def upper_snake?(name)
        name.match?(/\A[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*\z/)
      end

      def pascal?(name)
        name.match?(/\A[A-Z][A-Za-z0-9]*\z/)
      end

      # Words joined by underscores, a digit run kept on the word before it
      def joined(name)
        out = +""
        words(name).each do |word|
          out << "_" unless out.empty? || word.match?(/\A[0-9]/)
          out << word
        end
        out
      end
      private_class_method :joined
    end
  end
end
