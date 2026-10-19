# frozen_string_literal: true

module Protostar
  class Compiler
    # protoc's tokenizer (`io/tokenizer.cc`), byte for byte: the same token
    # boundaries, the same 0-based lines and columns (tabs advance to the next
    # multiple of 8), the same error messages and the same comment attachment
    # in #next_with_comments.
    class Lexer # :nodoc: all
      # A token. The lexer reuses its current token as it advances, as
      # protoc's Tokenizer does, and copies it into Lexer#previous.
      class Token
        # :start, :identifier, :integer, :float, :string, :symbol, :end,
        # and :whitespace or :newline when asked for.
        attr_accessor :type #: Symbol
        # The source text, quotes and escapes included for strings.
        attr_accessor :text #: String
        # 0-based.
        attr_accessor :line #: Integer
        # 0-based, a tab advancing to the next multiple of 8.
        attr_accessor :column #: Integer
        # 0-based column just after the token.
        attr_accessor :end_column #: Integer

        def initialize(type:, text:, line:, column:, end_column:)
          @type = type
          @text = text
          @line = line
          @column = column
          @end_column = end_column
        end

        # Returns the type, text, line, column and end column.
        #: () -> Array[untyped]
        def to_a
          [@type, @text, @line, @column, @end_column]
        end

        def inspect
          "#<#{self.class.name} #{to_a.inspect}>"
        end
      end

      TAB_WIDTH = 8

      LETTER = Array.new(256) { |b| b.between?(97, 122) || b.between?(65, 90) || b == 95 }.freeze
      DIGIT = Array.new(256) { |b| b.between?(48, 57) }.freeze
      ALNUM = Array.new(256) { |b| LETTER[b] || DIGIT[b] }.freeze
      OCTAL = Array.new(256) { |b| b.between?(48, 55) }.freeze
      HEX = Array.new(256) { |b| DIGIT[b] || b.between?(97, 102) || b.between?(65, 70) }.freeze
      # \t \n \v \f \r and space
      WHITESPACE = Array.new(256) { |b| b == 32 || b.between?(9, 13) }.freeze
      WHITESPACE_NO_NEWLINE = Array.new(256) { |b| WHITESPACE[b] && b != 10 }.freeze
      UNPRINTABLE = Array.new(256) { |b| b >= 1 && b < 32 }.freeze
      ESCAPE = Array.new(256) { |b| 'abfnrtv\\?\'"'.include?(b.chr) }.freeze

      ESCAPES = {
        "a" => 7, "b" => 8, "f" => 12, "n" => 10, "r" => 13, "t" => 9, "v" => 11,
        "\\" => 92, "?" => 63, "'" => 39, "\"" => 34
      }.freeze

      attr_reader :current, :previous #: Token
      attr_accessor :report_whitespace, :report_newlines

      # - `source`: the file's bytes
      # - `errors`: receives (line, column, message) for every error
      #: (String source, untyped errors) -> void
      def initialize(source, errors)
        @src = source.b
        @size = @src.bytesize
        @errors = errors
        @pos = 0
        @line = 0
        @column = 0
        @read_error = @size == 0
        @char = (@size == 0) ? 0 : @src.getbyte(0)
        @record_target = nil
        @record_start = -1
        @report_whitespace = false
        @report_newlines = false
        @current = Token.new(type: :start, text: +"", line: 0, column: 0, end_column: 0)
        @previous = @current.dup
      end

      # Advances to the next token, skipping whitespace and comments
      #
      # Returns false at the end of input.
      #: () -> bool
      def next
        @previous = @current.dup
        until @read_error
          start_token
          report = try_consume_whitespace || try_consume_newline
          end_token
          return true if report

          case try_consume_comment_start
          when :line
            consume_line_comment(nil)
            next
          when :block
            consume_block_comment(nil)
            next
          when :slash
            return true
          end

          break if @read_error

          if UNPRINTABLE[@char] || @char == 0
            add_error("Invalid control characters encountered in text.")
            next_char
            while try_consume_one(UNPRINTABLE) || (!@read_error && try_consume(0))
            end
          else
            start_token
            if try_consume_one(LETTER)
              consume_zero_or_more(ALNUM)
              @current.type = :identifier
            elsif try_consume(48) # 0
              @current.type = consume_number(true, false)
            elsif try_consume(46) # .
              if try_consume_one(DIGIT)
                if @previous.type == :identifier && @current.line == @previous.line &&
                    @current.column == @previous.end_column
                  @errors.call(@line, @column - 2, "Need space between identifier and decimal point.")
                end
                @current.type = consume_number(false, true)
              else
                @current.type = :symbol
              end
            elsif try_consume_one(DIGIT)
              @current.type = consume_number(false, false)
            elsif try_consume(34) # "
              consume_string(34)
              @current.type = :string
            elsif try_consume(39) # '
              consume_string(39)
              @current.type = :string
            else
              consume_symbol
              @current.type = :symbol
            end
            end_token
            return true
          end
        end

        @current.type = :end
        @current.text = +""
        @current.line = @line
        @current.column = @column
        @current.end_column = @column
        false
      end

      # Like #next, but collects the comments around the token boundary the
      # way protoc attaches them to declarations
      #
      # - `prev_trailing`: receives the previous token's trailing comment
      # - `detached`: receives detached comments
      # - `next_leading`: receives the next token's leading comment
      #: (String? prev_trailing, Array[String]? detached, String? next_leading) -> bool
      def next_with_comments(prev_trailing, detached, next_leading)
        collector = CommentCollector.new(prev_trailing, detached, next_leading)
        prev_line = @line
        trailing_comment_end_line = -1

        if @current.type == :start
          if try_consume(0xEF)
            unless try_consume(0xBB) && try_consume(0xBF)
              add_error("Proto file starts with 0xEF but not UTF-8 BOM. Only UTF-8 is accepted for proto file.")
              collector.finish
              return false
            end
          end
          collector.detach_from_prev
          prev_line = -1
        else
          consume_zero_or_more(WHITESPACE_NO_NEWLINE)
          case try_consume_comment_start
          when :line
            trailing_comment_end_line = @line
            consume_line_comment(collector.buffer_for_line_comment)
            collector.flush
          when :block
            consume_block_comment(collector.buffer_for_block_comment)
            trailing_comment_end_line = @line
            consume_zero_or_more(WHITESPACE_NO_NEWLINE)
            collector.flush
          when :slash
            collector.finish
            return true
          else
            unless try_consume(10)
              collector.finish
              return self.next
            end
          end
        end

        loop do
          consume_zero_or_more(WHITESPACE_NO_NEWLINE)
          case try_consume_comment_start
          when :line
            consume_line_comment(collector.buffer_for_line_comment)
          when :block
            consume_block_comment(collector.buffer_for_block_comment)
            consume_zero_or_more(WHITESPACE_NO_NEWLINE)
            try_consume(10)
          when :slash
            collector.finish
            return true
          else
            if try_consume(10)
              collector.flush
              collector.detach_from_prev
            else
              result = self.next
              text = @current.text
              collector.flush if !result || text == "}" || text == "]" || text == ")"
              if result && (prev_line == @line || trailing_comment_end_line == @line)
                collector.maybe_detach_comment
              end
              collector.finish
              return result
            end
          end
        end
      end

      # protoc's Tokenizer::ParseInteger: decimal, 0x hex or leading-zero octal
      #
      # Returns nil when malformed or above `max`.
      #: (untyped text, untyped max) -> Integer?
      def self.parse_integer(text, max)
        base = 10
        digits = text
        if text.start_with?("0x", "0X")
          base = 16
          digits = text[2..]
        elsif text.start_with?("0")
          base = 8
        end
        valid = case base
        when 16 then digits.match?(/\A\h*\z/)
        when 8 then digits.match?(/\A[0-7]*\z/)
        else digits.match?(/\A[0-9]*\z/)
        end
        return nil unless valid
        value = digits.empty? ? 0 : digits.to_i(base)
        (value > max) ? nil : value
      end

      # protoc's Tokenizer::ParseFloat over text the tokenizer accepted as a number
      #: (untyped text) -> Float
      def self.parse_float(text)
        m = text.match(/\A(\d*)(?:\.(\d*))?(?:[eE]([-+]?\d+))?/)
        int = m[1].empty? ? "0" : m[1]
        frac = (m[2].nil? || m[2].empty?) ? "0" : m[2]
        Float("#{int}.#{frac}e#{m[3] || "0"}")
      end

      # Whether strtod would consume all of `text` as a float, as
      # Tokenizer::TryParseFloat checks
      def self.float_text?(text)
        text.match?(/\A(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?[fF]?\z/)
      end

      # protoc's Tokenizer::ParseStringAppend: the bytes a string token denotes
      #
      # - `text`: token text including the quotes
      #
      # Returns a binary String.
      #: (String text, ?untyped) -> String
      def self.parse_string(text, out = "".b)
        bytes = text.b
        quote = bytes.getbyte(0)
        n = bytes.bytesize
        i = 1
        while i < n
          b = bytes.getbyte(i)
          if b == 92 && i + 1 < n # backslash
            i += 1
            c = bytes.getbyte(i)
            if OCTAL[c]
              code = c - 48
              if i + 1 < n && OCTAL[bytes.getbyte(i + 1)]
                i += 1
                code = code * 8 + bytes.getbyte(i) - 48
              end
              if i + 1 < n && OCTAL[bytes.getbyte(i + 1)]
                i += 1
                code = code * 8 + bytes.getbyte(i) - 48
              end
              out << (code & 0xFF)
            elsif c == 120 || c == 88 # x X
              code = 0
              if i + 1 < n && HEX[bytes.getbyte(i + 1)]
                i += 1
                code = bytes.getbyte(i).chr.to_i(16)
              end
              if i + 1 < n && HEX[bytes.getbyte(i + 1)]
                i += 1
                code = code * 16 + bytes.getbyte(i).chr.to_i(16)
              end
              out << code
            elsif c == 117 || c == 85 # u U
              len = (c == 117) ? 4 : 8
              hex = bytes.byteslice(i + 1, len)
              if hex.nil? || hex.bytesize < len || !hex.match?(/\A\h+\z/)
                out << c
              else
                code = hex.to_i(16)
                i += len
                if code >= 0xD800 && code < 0xDC00 && bytes.byteslice(i + 1, 2) == "\\u"
                  trail = bytes.byteslice(i + 3, 4)
                  if trail&.match?(/\A\h{4}\z/) && (t = trail.to_i(16)) >= 0xDC00 && t < 0xE000
                    code = 0x10000 + (((code - 0xD800) << 10) | (t - 0xDC00))
                    i += 6
                  end
                end
                append_utf8(code, out)
              end
            else
              out << (ESCAPES[c.chr] || 63)
            end
          elsif b == quote && i == n - 1
            # closing quote
          else
            out << b
          end
          i += 1
        end
        out
      end

      def self.append_utf8(code, out)
        if code <= 0x7F
          out << code
        elsif code <= 0x7FF
          out << (0xC0 | (code >> 6)) << (0x80 | (code & 0x3F))
        elsif code <= 0xFFFF
          out << (0xE0 | (code >> 12)) << (0x80 | ((code >> 6) & 0x3F)) << (0x80 | (code & 0x3F))
        elsif code <= 0x10FFFF
          out << (0xF0 | (code >> 18)) << (0x80 | ((code >> 12) & 0x3F)) <<
            (0x80 | ((code >> 6) & 0x3F)) << (0x80 | (code & 0x3F))
        else
          out << format("\\U%08x", code)
        end
      end

      # Returns whether `text` is a valid identifier.
      #: (untyped text) -> bool
      def self.identifier?(text)
        text.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      end

      private

      def add_error(message)
        @errors.call(@line, @column, message)
      end

      def next_char
        if @char == 10
          @line += 1
          @column = 0
        elsif @char == 9
          @column += TAB_WIDTH - @column % TAB_WIDTH
        else
          @column += 1
        end
        @pos += 1
        if @pos < @size
          @char = @src.getbyte(@pos)
        else
          @read_error = true
          @char = 0
        end
      end

      def record_to(target)
        @record_target = target
        @record_start = @pos
      end

      def stop_recording
        if @pos != @record_start
          @record_target << @src.byteslice(@record_start, [@pos, @size].min - @record_start)
        end
        @record_target = nil
        @record_start = -1
      end

      def start_token
        @current.type = :start
        @current.text = +""
        @current.line = @line
        @current.column = @column
        record_to(@current.text)
      end

      def end_token
        stop_recording
        @current.end_column = @column
      end

      def try_consume_one(table)
        return false unless table[@char]
        next_char
        true
      end

      def try_consume(byte)
        return false unless @char == byte
        next_char
        true
      end

      def consume_zero_or_more(table)
        next_char while table[@char]
      end

      def consume_one_or_more(table, error)
        if table[@char]
          next_char while table[@char]
        else
          add_error(error)
        end
      end

      # Consumes up to `count` hex digits, stopping at the first that is missing
      def consume_hex(count)
        count.times { return false unless try_consume_one(HEX) }
        true
      end

      def consume_string(delimiter)
        loop do
          case @char
          when 0
            add_error("Unexpected end of string.")
            return
          when 10
            add_error("Multiline strings are not allowed. Did you miss a \"?.")
            return
          when 92 # backslash
            next_char
            if try_consume_one(ESCAPE)
            elsif try_consume_one(OCTAL)
            elsif try_consume(120) || try_consume(88) # x X
              add_error("Expected hex digits for escape sequence.") unless try_consume_one(HEX)
            elsif try_consume(117) # u
              add_error("Expected four hex digits for \\u escape sequence.") unless consume_hex(4)
            elsif try_consume(85) # U
              valid = 2.times.all? { try_consume(48) } && (try_consume(48) || try_consume(49)) && consume_hex(5)
              add_error("Expected eight hex digits up to 10ffff for \\U escape sequence") unless valid
            else
              add_error("Invalid escape sequence in string literal.")
            end
          else
            if @char == delimiter
              next_char
              return
            end
            next_char
          end
        end
      end

      def consume_number(started_with_zero, started_with_dot)
        is_float = false
        if started_with_zero && (try_consume(120) || try_consume(88)) # x X
          consume_one_or_more(HEX, "\"0x\" must be followed by hex digits.")
        elsif started_with_zero && DIGIT[@char]
          consume_zero_or_more(OCTAL)
          if DIGIT[@char]
            add_error("Numbers starting with leading zero must be in octal.")
            consume_zero_or_more(DIGIT)
          end
        else
          if started_with_dot
            is_float = true
            consume_zero_or_more(DIGIT)
          else
            consume_zero_or_more(DIGIT)
            if try_consume(46) # .
              is_float = true
              consume_zero_or_more(DIGIT)
            end
          end
          if try_consume(101) || try_consume(69) # e E
            is_float = true
            try_consume(45) || try_consume(43) # - +
            consume_one_or_more(DIGIT, "\"e\" must be followed by exponent.")
          end
        end

        if LETTER[@char]
          add_error("Need space between number and identifier.")
        elsif @char == 46 # .
          if is_float
            add_error("Already saw decimal point or exponent; can't have another one.")
          else
            add_error("Hex and octal numbers must be integers.")
          end
        end
        is_float ? :float : :integer
      end

      def consume_symbol
        @errors.call(@line, @column, "Interpreting non ascii codepoint #{@char}.") if @char >= 0x80
        next_char
      end

      def consume_line_comment(content)
        record_to(content) if content
        next_char while @char != 0 && @char != 10
        try_consume(10)
        stop_recording if content
      end

      def consume_block_comment(content)
        start_line = @line
        start_column = @column - 2
        record_to(content) if content
        loop do
          next_char while @char != 0 && @char != 42 && @char != 47 && @char != 10 # * / \n
          if try_consume(10)
            stop_recording if content
            consume_zero_or_more(WHITESPACE_NO_NEWLINE)
            if try_consume(42) && try_consume(47) # * /
              break
            end
            record_to(content) if content
          elsif try_consume(42) && try_consume(47)
            if content
              stop_recording
              content.replace(content.byteslice(0, content.bytesize - 2))
            end
            break
          elsif try_consume(47) && @char == 42
            add_error("\"/*\" inside block comment.  Block comments cannot be nested.")
          elsif @char == 0
            add_error("End-of-file inside block comment.")
            @errors.call(start_line, start_column, "  Comment started here.")
            stop_recording if content
            break
          end
        end
      end

      def try_consume_comment_start
        return nil unless try_consume(47) # /
        if try_consume(47)
          :line
        elsif try_consume(42) # *
          :block
        else
          @current.type = :symbol
          @current.text = +"/"
          @current.line = @line
          @current.column = @column - 1
          @current.end_column = @column
          :slash
        end
      end

      def try_consume_whitespace
        if @report_newlines
          if try_consume_one(WHITESPACE_NO_NEWLINE)
            consume_zero_or_more(WHITESPACE_NO_NEWLINE)
            @current.type = :whitespace
            return true
          end
          return false
        end
        if try_consume_one(WHITESPACE)
          consume_zero_or_more(WHITESPACE)
          @current.type = :whitespace
          return @report_whitespace
        end
        false
      end

      def try_consume_newline
        return false unless @report_whitespace && @report_newlines
        if try_consume(10)
          @current.type = :newline
          return true
        end
        false
      end

      # tokenizer.cc's CommentCollector
      class CommentCollector
        def initialize(prev_trailing, detached, next_leading)
          @prev_trailing = prev_trailing
          @detached = detached
          @next_leading = next_leading
          prev_trailing&.clear
          detached&.clear
          next_leading&.clear
          @buffer = "".b
          @num_comments = 0
          @has_trailing_comment = false
          @has_comment = false
          @is_line_comment = false
          @can_attach_to_prev = true
        end

        def buffer_for_line_comment
          flush if @has_comment && !@is_line_comment
          @has_comment = true
          @is_line_comment = true
          @buffer
        end

        def buffer_for_block_comment
          flush if @has_comment
          @has_comment = true
          @is_line_comment = false
          @buffer
        end

        def clear_buffer
          @buffer = "".b
          @has_comment = false
        end

        def flush
          return unless @has_comment
          if @can_attach_to_prev
            @prev_trailing&.<<(@buffer)
            @has_trailing_comment = true
            @can_attach_to_prev = false
          else
            @detached&.push(@buffer)
          end
          clear_buffer
          @num_comments += 1
        end

        def detach_from_prev
          @can_attach_to_prev = false
        end

        def maybe_detach_comment
          count = @num_comments
          count += 1 if @has_comment
          return unless count == 1
          if @has_trailing_comment && @prev_trailing
            @detached&.unshift(@prev_trailing.dup)
            @prev_trailing.clear
          end
          flush
        end

        # The destructor: whatever is still buffered leads the next token
        def finish
          @next_leading&.replace(@buffer) if @next_leading && @has_comment
        end
      end
    end
  end
end
