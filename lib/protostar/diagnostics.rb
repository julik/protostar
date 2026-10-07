# frozen_string_literal: true

module Protostar
  # Diagnostics the way `rustc` prints them: the source line with the span
  # underlined, related spans with their own labels, `help:` and `note:`
  # lines, a code that `protostar lint --explain` looks up, and fixes. Both
  # the compiler's errors ({Compiler::Diagnostic}) and lint findings render
  # through here.
  #
  #   renderer = Protostar::Diagnostics::Renderer.new(source: ->(name) { File.read(name) })
  #   puts renderer.render(diagnostic)
  #
  # Lines and columns are 1-based and count as protoc counts them: bytes, a
  # tab advancing to the next multiple of 8.
  module Diagnostics
    autoload :Codes, ::File.expand_path("diagnostics/codes", __dir__)
    autoload :Source, ::File.expand_path("diagnostics/source", __dir__)
    autoload :Renderer, ::File.expand_path("diagnostics/renderer", __dir__)
    autoload :Formats, ::File.expand_path("diagnostics/formats", __dir__)

    # A stretch of source a diagnostic points at
    class Span
      # @return [Integer] 1-based
      attr_reader :line
      # @return [Integer] 1-based
      attr_reader :column
      # @return [Integer, nil] 1-based; nil when only the start is known, which
      #   renders as the token at the start
      attr_reader :end_line
      # @return [Integer, nil] 1-based, just past the last character
      attr_reader :end_column
      # @return [String, nil] printed next to the underline
      attr_reader :label

      def initialize(line, column, end_line = nil, end_column = nil, label: nil, primary: true)
        @line = line
        @column = column
        @end_line = end_line
        @end_column = end_column
        @label = label
        @primary = primary
        freeze
      end

      # The primary span gets the carets, the others dashes
      def primary?
        @primary
      end

      # @return [Span] the same span with another label
      def with_label(label)
        Span.new(@line, @column, @end_line, @end_column, label: label, primary: @primary)
      end

      # @return [Hash]
      def to_h
        {line: @line, column: @column, end_line: @end_line, end_column: @end_column, label: @label, primary: @primary}
      end

      def ==(other)
        other.is_a?(Span) && other.to_h == to_h
      end
      alias_method :eql?, :==

      def hash
        to_h.hash
      end
    end

    # One replacement in a file
    class Edit
      # @return [Integer] 1-based
      attr_reader :line
      # @return [Integer] 1-based
      attr_reader :column
      # @return [Integer]
      attr_reader :end_line
      # @return [Integer] 1-based, just past the replaced text; equal to {#column} to insert
      attr_reader :end_column
      # @return [String]
      attr_reader :text

      def initialize(line, column, end_line, end_column, text)
        @line = line
        @column = column
        @end_line = end_line
        @end_column = end_column
        @text = text.frozen? ? text : text.dup.freeze
        freeze
      end

      # @return [Hash]
      def to_h
        {line: @line, column: @column, end_line: @end_line, end_column: @end_column, text: @text}
      end
    end

    # A mechanical fix: what it does, in words, and the edits that do it
    class Fix
      # @return [String] e.g. "rename `colorRed` to `color_red`"
      attr_reader :description
      # @return [Array<Edit>]
      attr_reader :edits

      def initialize(description, edits)
        @description = description
        @edits = edits.freeze
        freeze
      end

      # @return [Hash]
      def to_h
        {description: @description, edits: @edits.map(&:to_h)}
      end
    end
  end
end
