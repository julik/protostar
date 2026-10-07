# frozen_string_literal: true

require "optparse"

module Protostar
  module Lint
    # `protostar lint`, the command line
    #
    #   protostar lint proto/                        # every *.proto under proto/, recursively
    #   protostar lint acme/person.proto --format json
    #   protostar lint proto/ --rules default,documentation --except FIELD_NOT_REQUIRED
    #   protostar lint --explain FIELD_NOT_REQUIRED
    #
    # Exits 0 when clean, 1 with warnings (0 with --warnings-ok), 2 with
    # errors, including mistakes on the command line.
    class Command
      USAGE = "Usage: protostar lint [OPTION] PROTO_FILES_OR_DIRS\n       protostar lint --explain CODE_OR_RULE"
      FORMATS = %w[text json github].freeze
      EXPLAIN_HINT = "For more about a code or rule, try `protostar lint --explain CODE`."

      def initialize(out, err)
        @out = out
        @err = err
      end

      # @param argv [Array<String>]
      # @return [Integer] the exit status
      def run(argv)
        opts = {}
        inputs = parser(opts).parse(argv)
        return explain(opts[:explain]) if opts[:explain]
        return list_rules if opts[:list]
        raise Error, "Missing input file or directory.\n#{USAGE}" if inputs.empty?
        config = opts[:config] ? Config.load(opts[:config]) : Config.find(inputs)
        rules = Lint.select(opts[:rules] || config.rules, except: (opts[:except] || []) + config.except)
        except = (opts[:except] || []) + config.except
        format = opts.fetch(:format, "text")
        raise Error, "Unknown format: #{format} (#{FORMATS.join(", ")})" unless FORMATS.include?(format)
        include, names = targets(inputs, opts[:include], config)
        raise Error, "No .proto files in #{inputs.join(", ")}." if names.empty?
        runner = Runner.new(include_paths: include, rules: rules, except: except.map { |e| Lint.rule_id(e) },
          directives: config.allow_comment_directives?)
        result = runner.run(names)
        fixed = fix(result, runner, write: opts[:fix], show: opts[:fix] || opts[:diff],
          diff_io: (format == "text") ? nil : @err)
        remaining = result.diagnostics.reject { |d| fixed.include?(d) }
        show(remaining, runner, format, opts, result)
        return 2 if remaining.any?(&:error?)
        return 1 if remaining.any?(&:warning?) && !opts[:warnings_ok]
        0
      rescue Error, OptionParser::ParseError, Compiler::Error => e
        @err.puts e.message
        2
      end

      private

      def parser(opts)
        OptionParser.new do |o|
          o.banner = USAGE
          o.on("-I", "--proto_path=PATH", "Directory to resolve names and imports against; repeatable, or colon-separated") do |v|
            (opts[:include] ||= []).concat(v.split(":"))
          end
          o.on("--rules=LIST", "Sets (minimal, default, strict), categories or rule ids; default: default") do |v|
            (opts[:rules] ||= []).concat(v.split(","))
          end
          o.on("--except=LIST", "Rule ids or codes to leave out") { |v| (opts[:except] ||= []).concat(v.split(",")) }
          o.on("--format=FORMAT", "text (default), json (one object per line) or github (workflow annotations)") do |v|
            opts[:format] = v
          end
          o.on("--color=WHEN", %w[auto always never], "auto (default: when stdout is a terminal and NO_COLOR is unset), always, never") do |v|
            opts[:color] = v
          end
          o.on("--warnings-ok", "Exit 0 when there are warnings but no errors") { opts[:warnings_ok] = true }
          o.on("--fix", "Apply the safe fixes (renames, a missing syntax line) and print the diff") { opts[:fix] = true }
          o.on("--diff", "Print the diff --fix would apply, change nothing") { opts[:diff] = true }
          o.on("--config=FILE", "Read FILE instead of looking for .protostar.yml") { |v| opts[:config] = v }
          o.on("--explain=CODE", "Explain a code (L0301) or rule (FIELD_NOT_REQUIRED, W0101)") { |v| opts[:explain] = v }
          o.on("--list-rules", "List the rules, their codes and sets") { opts[:list] = true }
        end
      end

      def explain(key)
        if (entry = Diagnostics::Codes[key])
          @out.puts "#{entry.code}: #{entry.summary}", "", entry.explanation
          return 0
        end
        id = Lint.rule_id(key)
        raise Error, "No code or rule #{key}." unless id
        rule = Lint.rule_class(id)
        @out.puts "#{rule.code}: #{id} (#{rule.tier} set, #{rule.category})", "", rule.reason, "", rule.explanation
        0
      end

      def list_rules
        RULES.each do |id, (code, tier, category)|
          @out.puts format("%-6s %-30s %-8s %-14s %s", code, id, tier, category, Lint.rule_class(id).reason)
        end
        0
      end

      # Include paths and the names of the files to lint. With -I, a path on
      # disk is named relative to the include path above it. Without, a file's
      # directory is its include path, and a directory is the include path of
      # the files under it.
      def targets(inputs, include, config)
        roots = []
        names = []
        inputs.each do |input|
          raise Error, "#{input}: No such file or directory" unless ::File.exist?(input)
          files = if ::File.directory?(input)
            Dir.glob("**/*.proto", base: input).sort.map { |f| ::File.join(input, f) }.reject { |f| config.ignored?(f) }
          else
            [input]
          end
          files.each do |file|
            if include
              name = virtual(file, include)
              raise Error, "#{file}: not under any include path (-I)" unless name
            else
              root = ::File.directory?(input) ? input : ::File.dirname(input)
              roots << root
              name = Compiler.canonical_path(::File.expand_path(file).delete_prefix("#{::File.expand_path(root)}/"))
            end
            names << name
          end
        end
        paths = include || roots.uniq { |r| ::File.expand_path(r) }
        [paths, names.uniq]
      end

      def virtual(file, include)
        path = ::File.expand_path(file)
        include.each do |dir|
          root = ::File.expand_path(dir)
          return path.delete_prefix("#{root}/") if path.start_with?("#{root}/")
        end
        nil
      end

      # The diff goes to stdout with text output, to stderr when stdout is JSON
      # or annotations
      def fix(result, runner, write:, show:, diff_io: nil)
        return [] unless show
        changes = Fixer.plan(result.diagnostics, text: ->(n) { runner.text(n) },
          path: ->(n) { result.contexts.find { |c| c.name == n }&.disk_path })
        changes.each do |change|
          (diff_io || @out).write(Fixer.diff(change))
          ::File.binwrite(change.path, change.after) if write && change.path
        end
        write ? changes.flat_map(&:fixed) : []
      end

      def show(diagnostics, runner, format, opts, result)
        sources = Hash.new { |h, name| h[name] = (text = runner.text(name)) && Diagnostics::Source.new(text) }
        case format
        when "json"
          diagnostics.each { |d| @out.puts Diagnostics::Formats.json(d, source: sources[d.file]) }
        when "github"
          diagnostics.each { |d| @out.puts Diagnostics::Formats.github(d, source: sources[d.file]) }
        else
          renderer = Diagnostics::Renderer.new(color: color?(opts[:color]), source: ->(d) { runner.text(d.file) })
          diagnostics.each { |d| @out.puts renderer.render(d) }
          @out.puts summary(diagnostics, result)
          @out.puts EXPLAIN_HINT unless diagnostics.empty?
        end
      end

      def summary(diagnostics, result)
        errors = diagnostics.count(&:error?)
        warnings = diagnostics.count(&:warning?)
        fixable = diagnostics.count(&:fix)
        files = result.names.size
        text = "#{files} #{(files == 1) ? "file" : "files"}: #{count(errors, "error")}, #{count(warnings, "warning")}"
        text += " (#{fixable} fixable with --fix)" if fixable > 0
        text
      end

      def count(n, word)
        "#{n} #{word}#{"s" unless n == 1}"
      end

      def color?(setting)
        case setting
        when "always" then true
        when "never" then false
        else CLI.color?(@out)
        end
      end
    end
  end
end
