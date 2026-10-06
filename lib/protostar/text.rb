# frozen_string_literal: true

module Protostar
  # protoc's text format: what `protoc --decode` prints and `--encode` reads.
  #
  #   text = Protostar::Text.print(person)      # also person.to_text
  #   Protostar::Text.parse(Person, text) == person
  #
  # Extensions have no API of their own yet: they travel as unknown fields.
  # The printer shows an unknown field as `[full.name]` when it is an
  # extension of the message known to its file (or to `pool:`), and the
  # parser turns `[full.name]` into the unknown field the binary codec would
  # have kept.
  module Text
    # Raised by everything in {Text}
    class Error < Protostar::Error; end

    # Raised for text that does not describe a message of the class it is
    # parsed into. The message starts with `line:column:`, both 1-based.
    class ParseError < Error
      # @return [Integer]
      attr_reader :line, :column

      def initialize(message, line, column)
        @line = line
        @column = column
        super("#{line}:#{column}: #{message}")
      end
    end

    class << self
      # @param message [Message]
      # @option options [Boolean] :single_line everything on one line, fields separated by spaces
      # @option options [Boolean] :expand_any print an Any whose type is known as
      #   `[type_url] { ... }`; off by default, as in `protoc --decode`
      #   (protoc's DebugString expands)
      # @option options [Boolean] :as_utf8 keep valid UTF-8 in strings readable instead of
      #   escaping every byte above 0x7e in octal as protoc does
      # @option options [Boolean] :unknown_fields false leaves unknown fields out, as
      #   protoc's Printer#SetHideUnknownFields does; extensions still print
      # @option options [Types::Registry] :registry where classes for Any and extensions are found
      # @option options [Schema::Pool, nil] :pool where extensions are found; by default
      #   the message's file and the files it imports
      # @return [String]
      def print(message, **options)
        Printer.new(**options).print(message)
      end

      # @param klass [Class] a message class
      # @param text [String]
      # @option options [Boolean] :allow_unknown_fields skip fields and extensions that are not known
      # @option options [Boolean] :allow_partial when false, raise if a required field is missing
      # @option options [Types::Registry] :registry where classes for Any and extensions are found
      # @option options [Schema::Pool, nil] :pool where extensions are found
      # @return [Message]
      # @raise [ParseError]
      def parse(klass, text, **options)
        Parser.new(text, **options).parse(klass)
      end
    end
  end
end

require_relative "text/tokenizer"
require_relative "text/extensions"
require_relative "text/printer"
require_relative "text/parser"
