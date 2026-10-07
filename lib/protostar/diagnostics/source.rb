# frozen_string_literal: true

module Protostar
  module Diagnostics
    # The text of one `.proto` file, read the way protoc counts positions:
    # 1-based lines, columns in bytes with a tab advancing to the next
    # multiple of 8. Maps those columns to what a terminal shows, finds the
    # token at a position, and applies {Edit}s.
    class Source
      TAB_WIDTH = 8
      TOKEN = /\A(?:[A-Za-z_][A-Za-z0-9_]*|0[xX][0-9A-Fa-f]+|[0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?[A-Za-z]?|
        \.[0-9]+(?:[eE][+-]?[0-9]+)?|"(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?)/x

      # @return [Array<String>] the lines, without their line ends, as UTF-8
      attr_reader :lines

      # @param text [String] the file's bytes
      def initialize(text)
        utf8 = text.dup.force_encoding(Encoding::UTF_8)
        utf8 = utf8.scrub("?") unless utf8.valid_encoding?
        @lines = utf8.split("\n", -1).map { |l| l.delete_suffix("\r") }
        @lines.pop if @lines.size > 1 && @lines.last.empty?
      end

      # @param number [Integer] 1-based; past the end is an empty line, where
      #   protoc reports errors at the end of input
      # @return [String]
      def line(number)
        @lines.fetch(number - 1, "")
      end

      # @return [Integer] the number of lines
      def size
        @lines.size
      end

      # @return [String] the line as shown: tabs expanded to the columns protoc counts
      def display(number)
        out = +""
        each_char(number) { |char, _, width, _| out << ((char == "\t") ? " " * width : char) }
        out
      end

      # @param number [Integer] 1-based line
      # @param column [Integer] 1-based protoc column
      # @return [Integer] the 1-based column a terminal shows it at
      def display_column(number, column)
        target = column - 1
        last_protoc = 0
        last_display = 0
        each_char(number) do |char, protoc, width, display|
          if target < protoc + ((char == "\t") ? width : char.bytesize)
            return display + 1 + ((char == "\t") ? target - protoc : 0)
          end
          last_protoc = protoc + ((char == "\t") ? width : char.bytesize)
          last_display = display + ((char == "\t") ? width : 1)
        end
        last_display + (target - last_protoc) + 1
      end

      # @return [Integer] the 1-based protoc column just past the token starting at
      #   the position (one character when no token starts there)
      def token_end(number, column)
        text = line(number)
        index = char_index(number, column)
        return column + 1 if index.nil? || index >= text.size
        rest = text[index..]
        token = rest[TOKEN] || rest[0]
        column + token.bytesize
      end

      # @return [Integer, nil] the 1-based column of the first character that is not
      #   whitespace, nil on a blank line
      def first_column(number)
        each_char(number) { |char, protoc, _, _| return protoc + 1 unless char.match?(/\s/) }
        nil
      end

      # @return [Integer] the 1-based column just past the last character
      def end_column(number)
        protoc = 0
        each_char(number) { |char, at, width, _| protoc = at + ((char == "\t") ? width : char.bytesize) }
        protoc + 1
      end

      # @return [Span] with its end filled in: the token at its start when unknown
      def resolve(span)
        return span if span.end_line
        Span.new(span.line, span.column, span.line, token_end(span.line, span.column), label: span.label,
          primary: span.primary?)
      end

      # @param edits [Array<Edit>] on this text, not overlapping
      # @return [String] the text with the edits made, line ends as they were
      def apply(text, edits)
        out = text.dup.force_encoding(Encoding::UTF_8)
        starts = line_starts(out)
        edits.sort_by { |e| [e.line, e.column] }.reverse_each do |edit|
          from = offset(out, starts, edit.line, edit.column)
          to = offset(out, starts, edit.end_line, edit.end_column)
          out = out.byteslice(0, from) + edit.text + out.byteslice(to..)
        end
        out
      end

      private

      def each_char(number)
        protoc = 0
        display = 0
        line(number).each_char do |char|
          width = (char == "\t") ? TAB_WIDTH - protoc % TAB_WIDTH : 1
          yield char, protoc, width, display
          protoc += (char == "\t") ? width : char.bytesize
          display += width
        end
      end

      def char_index(number, column)
        target = column - 1
        index = 0
        each_char(number) do |char, protoc, width, _|
          return index if target < protoc + ((char == "\t") ? width : char.bytesize)
          index += 1
        end
        index
      end

      def line_starts(text)
        bytes = text.b
        starts = [0]
        while (nl = bytes.index("\n", starts.last))
          starts << nl + 1
        end
        starts
      end

      # The byte offset of a protoc position in the text
      def offset(text, starts, number, column)
        start = starts.fetch(number - 1) { return text.bytesize }
        target = column - 1
        protoc = 0
        bytes = 0
        line(number).each_char do |char|
          return start + bytes if protoc >= target
          protoc += (char == "\t") ? TAB_WIDTH - protoc % TAB_WIDTH : char.bytesize
          bytes += char.bytesize
        end
        start + bytes
      end
    end
  end
end
