# frozen_string_literal: true

module Protostar
  module Lint
    # Applies the Diagnostics::Fixes lint findings carry, file by file. An
    # edit that overlaps one already taken is left out (the finding stays
    # unfixed), so the result never depends on two fixes agreeing.
    class Fixer
      CONTEXT = 3

      # The fixes for one file
      class Change
        # The file name as imported.
        attr_reader :name #: String
        # Where it is on disk.
        attr_reader :path #: String?
        attr_reader :before #: String
        attr_reader :after #: String
        # The findings fixed.
        attr_reader :fixed #: Array[Compiler::Diagnostic]

        def initialize(name, path, before, after, fixed)
          @name = name
          @path = path
          @before = before
          @after = after
          @fixed = fixed.freeze
          freeze
        end
      end

      # - `text`: the text of a file, by name
      # - `path`: where a file is on disk, by name, or nil
      #
      # Returns one per file with a fix.
      #: (Array[Compiler::Diagnostic] diagnostics, text: ^(String) -> String?, path: ^(String) -> String?) -> Array[Change]
      def self.plan(diagnostics, text:, path:)
        diagnostics.select(&:fix).group_by(&:file).filter_map do |name, found|
          before = text.call(name)
          next unless before
          taken = []
          fixed = found.select do |d|
            edits = d.fix.edits
            next false if edits.any? { |e| taken.any? { |t| overlap?(e, t) } }
            taken.concat(edits)
            true
          end
          after = Diagnostics::Source.new(before).apply(before, taken)
          Change.new(name, path.call(name), before, after, fixed)
        end
      end

      def self.overlap?(a, b)
        a_start = [a.line, a.column]
        a_end = [a.end_line, a.end_column]
        b_start = [b.line, b.column]
        b_end = [b.end_line, b.end_column]
        return a_start == b_start if a_start == a_end || b_start == b_end
        (a_start <=> b_end) < 0 && (b_start <=> a_end) < 0
      end
      private_class_method :overlap?

      # Returns a unified diff, as `diff -u` prints it.
      #: (Change change) -> String
      def self.diff(change)
        old_lines = change.before.split(/(?<=\n)/)
        new_lines = change.after.split(/(?<=\n)/)
        label = change.path || change.name
        old_label, new_label = label.start_with?("/") ? [label, label] : ["a/#{label}", "b/#{label}"]
        out = "--- #{old_label}\n+++ #{new_label}\n"
        hunks(old_lines, new_lines).each do |os, oe, ns, ne|
          out << "@@ -#{range(os, oe)} +#{range(ns, ne)} @@\n"
          i = os
          j = ns
          while i < oe || j < ne
            if i < oe && j < ne && old_lines[i] == new_lines[j]
              out << " " << terminated(old_lines[i])
              i += 1
              j += 1
            else
              changed_old, changed_new = block(old_lines, new_lines, i, j, oe, ne)
              changed_old.each { |l| out << "-" << terminated(l) }
              changed_new.each { |l| out << "+" << terminated(l) }
              i += changed_old.size
              j += changed_new.size
            end
          end
        end
        out
      end

      # The lines that differ, as aligned runs: lint's edits change lines in
      # place or insert whole lines, so a run ends where the two sides meet again
      def self.block(old_lines, new_lines, i, j, oe, ne)
        (0..[oe - i, ne - j].max).each do |skip|
          (0..skip).each do |a|
            b = skip - a
            next if i + a > oe || j + b > ne
            if (i + a == oe && j + b == ne) || (i + a < oe && j + b < ne && old_lines[i + a] == new_lines[j + b])
              return [old_lines[i, a], new_lines[j, b]] if a + b > 0
            end
          end
        end
        [old_lines[i...oe], new_lines[j...ne]]
      end
      private_class_method :block

      # Hunks as [old start, old end, new start, new end], 0-based, ends exclusive
      def self.hunks(old_lines, new_lines)
        prefix = 0
        prefix += 1 while prefix < old_lines.size && prefix < new_lines.size && old_lines[prefix] == new_lines[prefix]
        suffix = 0
        while suffix < old_lines.size - prefix && suffix < new_lines.size - prefix &&
            old_lines[-1 - suffix] == new_lines[-1 - suffix]
          suffix += 1
        end
        return [] if prefix == old_lines.size && prefix == new_lines.size
        changes = []
        i = prefix
        j = prefix
        oe = old_lines.size - suffix
        ne = new_lines.size - suffix
        while i < oe || j < ne
          if i < oe && j < ne && old_lines[i] == new_lines[j]
            i += 1
            j += 1
            next
          end
          a, b = block(old_lines, new_lines, i, j, oe, ne)
          changes << [i, i + a.size, j, j + b.size]
          i += a.size
          j += b.size
        end
        merged = []
        changes.each do |os, oe2, ns, ne2|
          if merged.any? && os - merged.last[1] <= 2 * CONTEXT
            merged.last[1] = oe2
            merged.last[3] = ne2
          else
            merged << [os, oe2, ns, ne2]
          end
        end
        merged.map do |os, oe2, ns, ne2|
          before = [CONTEXT, os].min
          after = [CONTEXT, old_lines.size - oe2].min
          [os - before, oe2 + after, ns - before, ne2 + after]
        end
      end
      private_class_method :hunks

      def self.range(start, finish)
        count = finish - start
        first = count.zero? ? start : start + 1
        (count == 1) ? first.to_s : "#{first},#{count}"
      end
      private_class_method :range

      def self.terminated(line)
        line.end_with?("\n") ? line : "#{line}\n\\ No newline at end of file\n"
      end
      private_class_method :terminated
    end
  end
end
