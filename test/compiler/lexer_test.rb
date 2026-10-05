# frozen_string_literal: true

require "test_helper"

# protoc's tokenizer (io/tokenizer.cc): token boundaries, 0-based positions,
# literals and the error messages it reports
class CompilerLexerTest < Minitest::Test
  L = Protostar::Compiler::Lexer

  def tokens(text)
    errors = []
    lexer = L.new(text, ->(line, column, message) { errors << [line, column, message] })
    out = []
    out << lexer.current.to_a while lexer.next
    [out, errors]
  end

  def test_token_types_and_positions
    toks, errors = tokens("message Foo {\n  int32 a = 0x1F; // c\n}")
    assert_empty errors
    assert_equal [
      [:identifier, "message", 0, 0, 7], [:identifier, "Foo", 0, 8, 11], [:symbol, "{", 0, 12, 13],
      [:identifier, "int32", 1, 2, 7], [:identifier, "a", 1, 8, 9], [:symbol, "=", 1, 10, 11],
      [:integer, "0x1F", 1, 12, 16], [:symbol, ";", 1, 16, 17], [:symbol, "}", 2, 0, 1]
    ], toks
  end

  def test_tabs_advance_to_the_next_multiple_of_eight
    toks, = tokens("a\tb\t\tc")
    assert_equal [[0, 1], [8, 9], [24, 25]], toks.map { |t| t[3..4] }
  end

  def test_numbers
    toks, errors = tokens("0 017 0x1f 12 1.5 .5 1. 1e10 1E-3 2.5e+2")
    assert_empty errors
    assert_equal %i[integer integer integer integer float float float float float float], toks.map(&:first)
    assert_equal [1.5, 0.5, 1.0, 1e10, 1e-3, 250.0], toks.select { |t| t[0] == :float }.map { |t| L.parse_float(t[1]) }
  end

  def test_number_errors
    {
      "0x" => "\"0x\" must be followed by hex digits.",
      "08" => "Numbers starting with leading zero must be in octal.",
      "1.2.3" => "Already saw decimal point or exponent; can't have another one.",
      "0x1.5" => "Hex and octal numbers must be integers.",
      "123abc" => "Need space between number and identifier.",
      "1e" => "\"e\" must be followed by exponent.",
      "foo.5" => "Need space between identifier and decimal point."
    }.each do |text, message|
      _, errors = tokens(text)
      assert_equal message, errors.first&.last, text
    end
  end

  def test_parse_integer
    assert_equal 255, L.parse_integer("0xff", 2**64 - 1)
    assert_equal 8, L.parse_integer("010", 100)
    assert_equal 2**64 - 1, L.parse_integer("18446744073709551615", 2**64 - 1)
    assert_nil L.parse_integer("18446744073709551616", 2**64 - 1)
    assert_nil L.parse_integer("2147483648", 2**31 - 1)
    assert_nil L.parse_integer("09", 100)
  end

  def test_string_escapes
    text = %q("\a\b\f\n\r\t\v\\\\\'\"\?\101\x41é\U0001F600😀")
    assert_equal "\a\b\f\n\r\t\v\\'\"?AAé😀😀".b, L.parse_string(text)
    assert_equal "abc".b, L.parse_string("'abc'")
  end

  def test_string_errors
    {
      %q("\q") => "Invalid escape sequence in string literal.",
      %q("\x") => "Expected hex digits for escape sequence.",
      %q("\u12") => "Expected four hex digits for \\u escape sequence.",
      %q("\U00200000") => "Expected eight hex digits up to 10ffff for \\U escape sequence",
      '"abc' => "Unexpected end of string.",
      "\"ab\ncd\"" => "Multiline strings are not allowed. Did you miss a \"?."
    }.each do |text, message|
      _, errors = tokens(text)
      assert_equal message, errors.first&.last, text
    end
  end

  def test_comments_are_skipped
    toks, errors = tokens("a // line\nb /* block\n * more */ c")
    assert_empty errors
    assert_equal %w[a b c], toks.map { |t| t[1] }
  end

  def test_comment_errors
    _, errors = tokens("a /* x /* y */")
    assert_equal "\"/*\" inside block comment.  Block comments cannot be nested.", errors.first.last
    _, errors = tokens("a /* never")
    assert_equal [[0, 10, "End-of-file inside block comment."], [0, 2, "  Comment started here."]], errors
  end

  def test_control_and_non_ascii_characters
    _, errors = tokens("a \x01 b")
    assert_equal [[0, 2, "Invalid control characters encountered in text."]], errors
    _, errors = tokens("a \xC3\xA9".b)
    assert_equal "Interpreting non ascii codepoint 195.", errors.first.last
  end

  def test_slash_alone_is_a_symbol
    toks, = tokens("a / b")
    assert_equal [:symbol, "/", 0, 2, 3], toks[1]
  end

  def test_identifier_check
    assert L.identifier?("foo_Bar9")
    refute L.identifier?("9foo")
    refute L.identifier?("")
  end
end
