# frozen_string_literal: true

module Protostar
  module Lint
    # The base of every lint rule. A rule is a class under Rules named after
    # its id (`FIELD_NOT_REQUIRED` is `Rules::FieldNotRequired`) with two
    # constants, `REASON` (one line) and `EXPLANATION` (why, an example, the
    # fix), and a #check that calls #report for every problem it finds.
    #
    # ```ruby
    # class Rules::PackageDefined < Rule
    #   REASON = "A file without a package puts its types in the global namespace."
    #   EXPLANATION = "..."
    #
    #   def check
    #     report(context.ast, :other, "file has no package") if context.file.package.empty?
    #   end
    # end
    # ```
    #
    # Rules read the compiled Schema::File, the AST positions and the source
    # info through Context; none parses anything.
    class Rule
      # Returns a name such as "FIELD_NOT_REQUIRED".
      #: () -> String
      def self.id
        name.split("::").last.gsub(/(?<=[a-z0-9])(?=[A-Z])/, "_").upcase
      end

      # Returns a name such as "W0101".
      #: () -> String
      def self.code
        RULES.fetch(id)[0]
      end

      # Returns the smallest set the rule is in.
      #: () -> Symbol
      def self.tier
        RULES.fetch(id)[1]
      end

      #: () -> Symbol
      def self.category
        RULES.fetch(id)[2]
      end

      #: () -> String
      def self.reason
        const_get(:REASON)
      end

      #: () -> String
      def self.explanation
        const_get(:EXPLANATION)
      end

      # The compiler codes whose warnings the rule reports as its own, so they
      # are not printed twice
      CLAIMS = [].freeze

      attr_reader :context #: Context
      # What #report collected.
      attr_reader :diagnostics #: Array[Compiler::Diagnostic]

      #: (Context context) -> void
      def initialize(context)
        @context = context
        @diagnostics = []
      end

      # Finds the rule's problems in #context
      #: () -> void
      def check
        raise NotImplementedError, "#{self.class} must define #check"
      end

      private

      # Records a problem at a node's recorded position
      #
      # - `kind`: the position kind: :name, :number, :type, ...
      # - `message`: the headline, lower case, no full stop
      # - `label`: under the span
      # - `help`: the concrete fix in words
      # - `fix`: when the fix is mechanical and safe
      # - `related`: other places
      # - `span`: instead of the node's position
      #: (Compiler::AST::Node node, Symbol kind, String message, ?label: String?, ?help: String?, ?fix: Diagnostics::Fix?, ?related: Array[[Compiler::AST::Node, Symbol, String]], ?span: Diagnostics::Span?) -> untyped
      def report(node, kind, message, label: nil, help: nil, fix: nil, related: [], span: nil)
        span ||= @context.span(node, kind, label: label)
        span = span.with_label(label) if span && label && span.label.nil?
        spans = span ? [span] : []
        related.each do |other, other_kind, other_label|
          extra = @context.span(other, other_kind, label: other_label, primary: false)
          spans << extra if extra
        end
        add(message, spans, help: help, fix: fix)
      end

      # Records a problem at a span, or at none
      def add(message, spans, help: nil, fix: nil)
        first = spans.first
        note = "rule #{self.class.id} (#{self.class.tier} set)"
        @diagnostics << Compiler::Diagnostic.new(@context.name, first&.line, first&.column, message, :warning,
          path: @context.path, spans: spans, code: self.class.code, title: message, help: [help].compact,
          notes: [note], fix: fix, rule: self.class.id)
      end

      # - `numbers`: sorted
      #
      # Returns "2, 4 to 6".
      #: (Array[Integer] numbers) -> String
      def numbers_text(numbers)
        numbers.slice_when { |a, b| b != a + 1 }.map { |run| (run.size == 1) ? run[0].to_s : "#{run[0]} to #{run[-1]}" }.join(", ")
      end

      # A rename of the identifier under a span, offered only when the old
      # name appears once in the file (no reference, option or comment would
      # be left behind) and the new one not at all
      #: (untyped span, untyped from, untyped to) -> Diagnostics::Fix?
      def rename(span, from, to)
        return nil unless span && @context.renamable?(from, to)
        Diagnostics::Fix.new("rename `#{from}` to `#{to}`",
          [Diagnostics::Edit.new(span.line, span.column, span.end_line, span.end_column, to)])
      end
    end
  end
end
