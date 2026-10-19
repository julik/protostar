# frozen_string_literal: true

require "strscan"

module Protostar
  module Text
    # Splits text format into tokens the way protoc's io::Tokenizer does:
    # identifiers, integers (decimal, hex, octal), floats (an `f` suffix
    # allowed), quoted strings, and single-character symbols. `#` starts a
    # comment that runs to the end of the line.
    class Tokenizer # :nodoc: all
      # One token: `type` is :identifier, :integer, :float, :string, :symbol
      # or :eof, `text` its source text, `pos` its byte offset
      class Token
        attr_reader :type, :text, :pos

        def initialize(type, text, pos)
          @type = type
          @text = text
          @pos = pos
          freeze
        end

        def ==(other)
          other.is_a?(Token) && other.type == @type && other.text == @text && other.pos == @pos
        end
      end

      SKIP = /(?:\s+|#[^\n]*)+/
      IDENTIFIER = /[A-Za-z_][A-Za-z0-9_]*/
      HEX = /0[xX][0-9A-Fa-f]+/
      FLOAT = /(?:\d+\.\d*|\.\d+)(?:[eE][-+]?\d+)?[fF]?|\d+[eE][-+]?\d+[fF]?|\d+[fF]/
      INTEGER = /\d+/
      STRING = /"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/
      NUMBER_TAIL = /[A-Za-z0-9_.]/
      URL_CHARS = %r{[A-Za-z0-9_\-.~!$&()*+,;=%/]+}

      def initialize(text)
        @text = text
        @scanner = StringScanner.new(text)
        @peeked = nil
      end

      # Returns the next token without consuming it.
      #: () -> Token
      def peek
        @peeked ||= scan
      end

      # Returns the next token, consumed.
      #: () -> Token
      def next
        t = peek
        @peeked = nil
        t
      end

      # What protoc's tokenizer reads in URL mode between `[` and `]`: runs of
      # URL characters, joined, with whitespace and comments between them
      # dropped. Call it right after consuming the `[`.
      #
      # Returns the text and where it starts.
      #: () -> [String, Integer]
      def url_chars
        raise ArgumentError, "a token was peeked past the [" if @peeked
        @scanner.skip(SKIP)
        pos = @scanner.pos
        text = +""
        while (run = @scanner.scan(URL_CHARS))
          text << run
          @scanner.skip(SKIP)
        end
        [text, pos]
      end

      # Returns 1-based line and column of a byte position.
      #: (untyped pos) -> [Integer, Integer]
      def line_col(pos)
        before = @text.byteslice(0, pos)
        line = before.count("\n") + 1
        last = before.rindex("\n")
        [line, before.length - (last ? last + 1 : 0) + 1]
      end

      # Raises ParseError.
      def fail!(message, pos)
        raise ParseError.new(message, *line_col(pos))
      end

      private

      def scan
        s = @scanner
        s.skip(SKIP)
        pos = s.pos
        return Token.new(:eof, "", pos) if s.eos?
        if (t = s.scan(IDENTIFIER))
          Token.new(:identifier, t, pos)
        elsif (t = s.scan(HEX))
          number(:integer, t, pos)
        elsif (t = s.scan(FLOAT))
          number(:float, t, pos)
        elsif (t = s.scan(INTEGER))
          number(:integer, t, pos)
        elsif (t = s.scan(STRING))
          Token.new(:string, t, pos)
        elsif s.check(/["']/)
          fail!("unterminated string", pos)
        else
          Token.new(:symbol, s.getch, pos)
        end
      end

      def number(type, text, pos)
        fail!("need space between number and identifier", @scanner.pos) if @scanner.check(NUMBER_TAIL)
        Token.new(type, text, pos)
      end
    end
  end
end
