# frozen_string_literal: true

require "json"

module Protostar
  module Diagnostics
    # Diagnostics for machines: one JSON object per diagnostic (JSON Lines),
    # or GitHub Actions workflow commands, which annotate the lines of a pull
    # request.
    module Formats
      # @param diagnostic [Compiler::Diagnostic]
      # @param source [Source, nil] the file's text, to find where spans end
      # @return [Hash] code, severity, message, file, path, line, column, spans,
      #   help, notes, fix and rule; the message is the short title, `protoc` the
      #   compiler's own wording when that differs
      def self.record(diagnostic, source: nil)
        d = diagnostic.annotated
        spans = d.spans
        spans = [Span.new(d.line, d.column)] if spans.empty? && d.line
        spans = spans.map { |s| source.resolve(s) } if source
        out = {code: d.code, severity: d.severity.to_s, message: d.title}
        out[:protoc] = d.message if d.title != d.message
        out.merge!(file: d.file, path: d.path, line: d.line, column: d.column, spans: spans.map(&:to_h),
          help: d.help, notes: d.notes, fix: d.fix&.to_h, rule: d.rule)
        out
      end

      # @return [String] one line of JSON
      def self.json(diagnostic, source: nil)
        ::JSON.generate(record(diagnostic, source: source))
      end

      # @return [String] an `::error` or `::warning` workflow command
      def self.github(diagnostic, source: nil)
        d = diagnostic.annotated
        props = {"file" => d.path || d.file}
        if d.line
          span = d.spans.first || Span.new(d.line, d.column)
          span = source.resolve(span) if source
          props["line"] = span.line
          props["col"] = span.column
          if span.end_line
            props["endLine"] = span.end_line
            props["endColumn"] = span.end_column
          end
        end
        props["title"] = d.code if d.code
        text = [d.title, *d.help.map { |h| "help: #{h}" }, *d.notes.map { |n| "note: #{n}" }]
        text << "fix: #{d.fix.description}" if d.fix
        kind = d.error? ? "error" : "warning"
        "::#{kind} #{props.map { |k, v| "#{k}=#{escape_property(v.to_s)}" }.join(",")}::#{escape_data(text.join("\n"))}"
      end

      def self.escape_data(text)
        text.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
      end

      def self.escape_property(text)
        escape_data(text).gsub(":", "%3A").gsub(",", "%2C")
      end
      private_class_method :escape_data, :escape_property
    end
  end
end
