# frozen_string_literal: true

module Protostar
  module Lint
    # Compiles each file on its own, so one that fails does not stop the
    # others, sharing one pool so imports are built once; then runs the rules
    # over every file that compiled.
    #
    # The compiler's diagnostics come first, in the order it reports them
    # (protoc's): errors from any file, warnings for the files asked about.
    # Then each file's lint findings, in file order and by position within a
    # file. Comment directives switch off warnings, never errors.
    class Runner
      # What a run found
      class Result
        attr_reader :diagnostics #: Array[Compiler::Diagnostic]
        # The files that compiled.
        attr_reader :contexts #: Array[Context]
        # Every file asked about.
        attr_reader :names #: Array[String]

        def initialize(diagnostics, contexts, names)
          @diagnostics = diagnostics.freeze
          @contexts = contexts.freeze
          @names = names.freeze
          freeze
        end

        #: () -> bool
        def errors?
          @diagnostics.any?(&:error?)
        end

        #: () -> bool
        def warnings?
          @diagnostics.any?(&:warning?)
        end
      end

      attr_reader :compiler #: Compiler

      # - `include_paths`: where file names and imports are resolved
      # - `rules`: rule ids to run, from Lint.select
      # - `except`: rule ids switched off by name; the compiler
      #   warnings they would report are not passed through either
      # - `directives`: honour `// protostar-lint:` comments
      #: (include_paths: Array[String], rules: Array[String], ?except: Array[String], ?directives: bool) -> void
      def initialize(include_paths:, rules:, except: [], directives: true)
        @compiler = Compiler.new(include_paths: include_paths)
        @rules = rules.map { |id| Lint.rule_class(id) }
        @claimed = (rules + except).flat_map { |id| Lint.rule_class(id)::CLAIMS }.uniq
        @directives = directives
        @texts = {}
      end

      # - `names`: file names relative to an include path
      # - `sources`: file contents by name, before the include paths
      #: (Array[String] names, ?sources: Hash[String, String]) -> Result
      def run(names, sources: {})
        @sources = sources
        reported = []
        seen = {}
        linkers = {}
        names.each do |name|
          run = Compiler::Run.new(@compiler, [name], true, sources: sources, all_direct: true)
          if linkers[name]
            # built as an import of an earlier file: only the checks protoc
            # runs on the files it is given are left
            Compiler::Validator.cli_checks([linkers[name]], run)
          else
            run.call
          end
          run.diagnostics.each do |d|
            next if seen[d]
            seen[d] = true
            reported << d
          end
          names.each { |n| linkers[n] ||= run.linker(n) }
        end
        failed = reported.select(&:error?).map(&:file).uniq
        contexts = []
        names.each do |name|
          next if linkers[name].nil? || failed.include?(name)
          warnings = reported.select { |d| d.warning? && d.file == name }
          contexts << Context.new(name: name, path: shown_path(name), disk_path: disk_path(name),
            linker: linkers[name], text: text(name), warnings: warnings, all: contexts)
        end
        diagnostics = reported.select do |d|
          d.error? || (names.include?(d.file) && !@claimed.include?(d.code) && !suppressed?(d))
        end
        contexts.each { |context| diagnostics.concat(lint(context)) }
        Result.new(diagnostics, contexts, names)
      end

      # Returns the file's text, from the sources given or from disk.
      #: (String name) -> String?
      def text(name)
        return @texts[name] if @texts.key?(name)
        @texts[name] = if @sources&.key?(name)
          @sources[name]
        elsif (path = @compiler.resolve(name))
          ::File.binread(path)
        end
      end

      private

      def lint(context)
        found = @rules.flat_map do |rule_class|
          rule = rule_class.new(context)
          rule.check
          rule.diagnostics
        end
        found.reject! { |d| suppressed?(d) }
        found.each_with_index.sort_by { |d, i| [d.line || 0, d.column || 0, i] }.map(&:first)
      end

      def suppressed?(diagnostic)
        return false unless @directives && diagnostic.warning?
        @parsed ||= {}
        directives = @parsed[diagnostic.file] ||= (text = text(diagnostic.file)) && Directives.new(text)
        directives ? directives.suppressed?(diagnostic) : false
      end

      def shown_path(name)
        return nil if @sources.key?(name)
        @compiler.disk_path(name)
      end

      def disk_path(name)
        return nil if @sources.key?(name)
        @compiler.resolve(name)
      end
    end
  end
end
