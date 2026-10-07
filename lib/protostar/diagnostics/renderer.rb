# frozen_string_literal: true

module Protostar
  module Diagnostics
    # Prints a {Compiler::Diagnostic} the way rustc prints its own:
    #
    #   error[L0301]: field number 1 is already used in `p.A`
    #    --> link.proto:5:15
    #     |
    #   4 |   Missing m = 1;
    #     |               - first used by `m`
    #   5 |   int32 dup = 1;
    #     |               ^ reused here
    #     |
    #     = help: the next available field number is 2
    #
    # The primary span gets carets, related spans dashes, each with its label;
    # a span over several lines is drawn down the left margin. Without the
    # source, only the header, location and the `help:` and `note:` lines print.
    class Renderer
      COLORS = {
        error: "\e[1;31m", warning: "\e[1;33m", secondary: "\e[1;34m", gutter: "\e[1;34m", bold: "\e[1m",
        help: "\e[1;36m", reset: "\e[0m"
      }.freeze
      # Lines of a multi-line span shown between its first and last before `...`
      INNER_LINES = 3

      # @param color [Boolean] ANSI colours, for a terminal
      # @param source [#call, nil] given the diagnostic, returns its file's text (or nil)
      def initialize(color: false, source: nil)
        @color = color
        @source = source
        @texts = {}
      end

      # @param diagnostic [Compiler::Diagnostic]
      # @return [String] the rendered diagnostic, ending in a newline
      def render(diagnostic)
        d = diagnostic.annotated
        out = +""
        out << header(d) << "\n"
        source = source_for(d)
        spans = d.line ? spans_of(d, source) : []
        width = [*spans.flat_map { |s| [s.line, s.end_line] }, d.line || 0].max.to_s.size
        pad = " " * width
        if d.line
          out << "#{pad}#{paint("-->", :gutter)} #{d.path || d.file}:#{d.line}:#{d.column}\n"
        elsif d.file
          out << "#{pad}#{paint("-->", :gutter)} #{d.path || d.file}\n"
        end
        if source && !spans.empty?
          out << "#{pad} #{paint("|", :gutter)}\n"
          snippet(out, source, spans, d.severity, width)
        end
        footer = d.help.map { |h| ["help", h] } + d.notes.map { |n| ["note", n] }
        footer << ["fix", d.fix.description] if d.fix
        unless footer.empty?
          out << "#{pad} #{paint("|", :gutter)}\n" if source && !spans.empty?
          footer.each do |kind, text|
            first, *rest = text.split("\n")
            out << "#{pad} #{paint("=", :gutter)} #{paint("#{kind}:", (kind == "note") ? :bold : :help)} #{first}\n"
            rest.each { |line| out << "#{pad}   #{" " * (kind.size + 2)}#{line}\n" }
          end
        end
        out
      end

      # @param diagnostic [Compiler::Diagnostic]
      # @return [Source, nil]
      def source_for(diagnostic)
        return nil unless @source && diagnostic.file
        key = diagnostic.path || diagnostic.file
        return @texts[key] if @texts.key?(key)
        text = @source.call(diagnostic)
        @texts[key] = text && Source.new(text)
      end

      private

      def header(d)
        label = d.error? ? "error" : "warning"
        label += "[#{d.code}]" if d.code
        "#{paint(label, d.severity)}#{paint(": #{d.title}", :bold)}"
      end

      def paint(text, kind)
        return text unless @color
        "#{COLORS.fetch(kind)}#{text}#{COLORS[:reset]}"
      end

      def spans_of(d, source)
        spans = d.spans.empty? ? [Span.new(d.line, d.column)] : d.spans
        return spans unless source
        spans.map do |span|
          span = source.resolve(span)
          next span if span.end_line > span.line || span.end_column > span.column
          Span.new(span.line, span.column, span.line, span.column + 1, label: span.label, primary: span.primary?)
        end
      end

      # One underline on one line, in display columns
      class Mark
        attr_reader :start, :finish, :primary, :label

        def initialize(start, finish, primary, label)
          @start = start
          @finish = finish
          @primary = primary
          @label = label
        end
      end

      def snippet(out, source, spans, severity, width)
        multi = spans.find { |s| s.end_line > s.line }
        multi = nil if multi && multi.end_line > source.size + 1
        marks = Hash.new { |h, k| h[k] = [] }
        spans.each do |span|
          next if span.equal?(multi)
          finish = (span.end_line == span.line) ? span.end_column : source.end_column(span.line)
          start = source.display_column(span.line, span.column)
          stop = [source.display_column(span.line, finish), start + 1].max
          marks[span.line] << Mark.new(start, stop, span.primary?, span.label)
        end
        shown = marks.keys
        if multi
          inner = ((multi.line + 1)...multi.end_line).to_a
          inner = inner.first(INNER_LINES) + [nil] if inner.size > INNER_LINES + 1
          shown += [multi.line, multi.end_line] + inner.compact
        end
        shown = shown.uniq.sort
        margin = multi ? 2 : 0
        prev = nil
        shown.each do |line|
          if prev && line > prev + 1
            if line == prev + 2
              source_line(out, source, prev + 1, width, gutter_margin(multi, prev + 1, source, severity), margin)
            else
              out << "#{paint("...", :gutter)}\n"
            end
          end
          source_line(out, source, line, width, gutter_margin(multi, line, source, severity), margin)
          if multi && line == multi.line && !slash_start?(multi, source)
            col = source.display_column(line, multi.column)
            row = " #{paint("_" * col + marker(multi), multi.primary? ? severity : :secondary)}"
            out << "#{" " * width} #{paint("|", :gutter)} #{row}\n"
          end
          marks[line].empty? || annotate(out, marks[line], width, inside?(multi, line) ? :bar : :blank, severity, margin)
          if multi && line == multi.end_line
            last = [source.display_column(line, multi.end_column) - 1, 1].max
            kind = multi.primary? ? severity : :secondary
            row = paint("|#{"_" * last}#{marker(multi)}", kind)
            row += " #{paint(multi.label, kind)}" if multi.label
            out << "#{" " * width} #{paint("|", :gutter)} #{row}\n"
          end
          prev = line
        end
      end

      def slash_start?(multi, source)
        source.first_column(multi.line) == multi.column
      end

      def inside?(multi, line)
        multi && line > multi.line && line <= multi.end_line
      end

      def gutter_margin(multi, line, source, severity)
        return "" unless multi
        kind = multi.primary? ? severity : :secondary
        if line == multi.line
          slash_start?(multi, source) ? paint("/", kind) + " " : "  "
        elsif line > multi.line && line <= multi.end_line
          paint("|", kind) + " "
        else
          "  "
        end
      end

      def marker(span)
        span.primary? ? "^" : "-"
      end

      def source_line(out, source, line, width, margin_text, margin)
        text = source.display(line)
        number = paint(line.to_s.rjust(width), :gutter)
        body = margin.zero? ? text : margin_text + text
        out << "#{number} #{paint("|", :gutter)}#{" #{body}" unless body.empty?}\n"
      end

      # The underline row, and below it the labels that do not fit at its end,
      # each hanging from its span by a `|`
      def annotate(out, marks, width, margin_kind, severity, margin)
        marks = marks.sort_by { |m| [m.start, m.primary ? 1 : 0] }
        prefix = "#{" " * width} #{paint("|", :gutter)} "
        lead = if margin.zero?
          ""
        else
          (margin_kind == :bar) ? paint("|", severity) + " " : "  "
        end
        cells = Array.new(marks.map(&:finish).max - 1, " ")
        kinds = Array.new(cells.size)
        marks.each do |m|
          (m.start...m.finish).each do |c|
            next if kinds[c - 1] && !m.primary
            cells[c - 1] = m.primary ? "^" : "-"
            kinds[c - 1] = m.primary ? severity : :secondary
          end
        end
        labelled = marks.select(&:label)
        last = labelled.max_by(&:start)
        row = paint_cells(cells, kinds)
        row += " #{paint(last.label, last.primary ? severity : :secondary)}" if last && last.start == marks.map(&:start).max
        out << "#{prefix}#{lead}#{row.rstrip}\n"
        hanging = labelled.reject { |m| m.equal?(last) && last.start == marks.map(&:start).max }.sort_by(&:start)
        until hanging.empty?
          connectors = Array.new(hanging.last.start, " ")
          ckinds = Array.new(connectors.size)
          hanging.each do |m|
            connectors[m.start - 1] = "|"
            ckinds[m.start - 1] = m.primary ? severity : :secondary
          end
          out << "#{prefix}#{lead}#{paint_cells(connectors, ckinds).rstrip}\n"
          m = hanging.pop
          labels = Array.new(m.start - 1, " ")
          lkinds = Array.new(labels.size)
          hanging.each do |h|
            labels[h.start - 1] = "|"
            lkinds[h.start - 1] = h.primary ? severity : :secondary
          end
          out << "#{prefix}#{lead}#{paint_cells(labels, lkinds)}#{paint(m.label, m.primary ? severity : :secondary)}\n"
        end
      end

      def paint_cells(cells, kinds)
        return cells.join unless @color
        cells.each_with_index.map { |c, i| (kinds[i] && c != " ") ? paint(c, kinds[i]) : c }.join
      end
    end
  end
end
