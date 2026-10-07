# frozen_string_literal: true

module Protostar
  module Lint
    # Case conversions as buf's naming rules apply them
    module Naming
      module_function

      # @return [Array<String>] the words of a name in any case: "HTTPServer_v2" is HTTP, Server, v2
      def words(name)
        name.split(/_+/).flat_map { |part| part.scan(/[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+[a-z]*|[A-Z]+/) }
          .reject(&:empty?)
      end

      # @return [String] "fooBar" as "foo_bar"
      def lower_snake(name)
        joined(name).downcase
      end

      # @return [String] "fooBar" as "FOO_BAR"
      def upper_snake(name)
        joined(name).upcase
      end

      # @return [String] "foo_bar" as "FooBar"
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
