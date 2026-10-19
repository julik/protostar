# frozen_string_literal: true

module Protostar
  module Lint
    # Comments that switch rules off for part of a file:
    #
    # ```ruby
    # // protostar-lint: disable-next-line FIELD_NOT_REQUIRED
    # required string id = 1;
    #
    # // protostar-lint: disable COMMENT_FIELD, COMMENT_MESSAGE
    # ...
    # // protostar-lint: enable COMMENT_FIELD, COMMENT_MESSAGE
    # ```
    #
    # A directive names rule ids or codes (a compiler warning's code works
    # too), or none for every rule. `disable` without `enable` runs to the end
    # of the file. Directives are read from the text line by line.
    class Directives
      PATTERN = %r{//\s*protostar-lint:\s*(disable-next-line|disable|enable)\b([^\n]*)}

      # - `text`: the file's bytes
      #: (String text) -> void
      def initialize(text)
        @next_line = Hash.new { |h, k| h[k] = [] }
        @ranges = []
        open = {}
        lines = text.b.split("\n", -1)
        lines.each_with_index do |line, i|
          match = PATTERN.match(line)
          next unless match
          names = match[2].split(/[\s,]+/).reject(&:empty?).map(&:upcase)
          names = [:all] if names.empty?
          number = i + 1
          case match[1]
          when "disable-next-line" then names.each { |n| @next_line[number + 1] << n }
          when "disable" then names.each { |n| open[n] ||= number }
          when "enable"
            ((names == [:all]) ? open.keys : names).each do |n|
              start = open.delete(n) || open.delete(:all)
              @ranges << [n, start, number] if start
            end
          end
        end
        open.each { |n, start| @ranges << [n, start, lines.size + 1] }
      end

      # Returns whether a directive switches it off where it starts.
      #: (Compiler::Diagnostic diagnostic) -> bool
      def suppressed?(diagnostic)
        line = diagnostic.line
        return false unless line
        keys = [diagnostic.rule, diagnostic.code, :all].compact
        return true if @next_line.key?(line) && @next_line[line].any? { |n| keys.include?(n) }
        @ranges.any? { |n, from, to| keys.include?(n) && line > from && line < to }
      end
    end
  end
end
