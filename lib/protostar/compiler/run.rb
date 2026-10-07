# frozen_string_literal: true

module Protostar
  class Compiler
    # One {Compiler#compile} call: loads the named files and their imports
    # depth first, as protoc's importer does (a file is parsed, then its
    # imports are built, then the file itself), and collects diagnostics in
    # protoc's order.
    #
    # @api private
    class Run
      # @return [Array<Diagnostic>]
      attr_reader :diagnostics

      # @param compiler [Compiler]
      # @param names [Array<String>] the files asked for
      # @param source_info [Boolean]
      # @param sources [Hash{String => String}] file contents to use instead of reading include paths
      # @param protoc_cli [Boolean] behave like protoc's command line (see {Linker#initialize});
      #   false behaves like a bare DescriptorPool, which loads no imports itself
      # @param all_direct [Boolean] check every file loaded as if it had been named, imports
      #   included (unused imports, deprecated features), as `protostar lint` wants
      def initialize(compiler, names, source_info, sources: {}, protoc_cli: true, all_direct: false)
        @compiler = compiler
        @pool = compiler.pool
        @names = names
        @source_info = source_info
        @sources = sources
        @protoc_cli = protoc_cli
        @all_direct = all_direct
        @diagnostics = []
        @pending = []
        @done = {}
        @failed = false
        @order = []
        @listed = {}
        @linkers = {}
      end

      def failed?
        @failed || @diagnostics.any?(&:error?)
      end

      # @return [Linker, nil] the linker of a file this run built
      def linker(name)
        @linkers[name]
      end

      # @return [Array<Schema::File>]
      def call
        direct = []
        @names.each do |name|
          file = load(name, direct: true)
          if file.nil?
            @failed = true
            break
          end
          direct << @linkers[name] if @linkers[name]
        end
        Validator.cli_checks(direct, self) if @protoc_cli && !failed?
        @order
      end

      # Records a diagnostic with a 0-based position (nil for none)
      # @param spans [Array<Diagnostics::Span>] where the renderer underlines, when known
      def report(file, position, message, severity = :error, spans: [])
        line, column = position
        line = nil if line && line < 0
        path = @compiler.disk_path(file) if file && !@sources.key?(file) && @protoc_cli
        @diagnostics << Diagnostic.new(file, line && line + 1, line && column + 1, message, severity, path: path,
          spans: line ? spans : [])
      end

      private

      # The problem's own span, as long as the source location that starts
      # where it is reported, then the places it relates to
      def spans(ast, problem, position)
        return [] unless position
        out = [span(ast, position, nil, true)]
        problem.related.each do |node, kind, label|
          at = node.position(kind)
          out << span(ast, at, label, false) if at
        end
        out
      end

      def span(ast, position, label, primary)
        line, column = position
        end_line, end_column = SourceInfo.extent(ast.locations, line, column)
        Diagnostics::Span.new(line + 1, column + 1, end_line && end_line + 1, end_column && end_column + 1,
          label: label, primary: primary)
      end

      # An extension number another file already uses is a warning the linker
      # reports as a diagnostic, so the pool is asked not to print it too
      def add_to_pool(name, file)
        @pool.add(file, warn: false)
      rescue Schema::Error => e
        report(name, nil, e.message)
        nil
      end

      def list(file)
        return if @listed[file.name]
        file.dependency_files.each { |dep| list(dep) }
        @listed[file.name] = true
        @order << file
      end

      def read(name)
        return @sources[name] if @sources.key?(name)
        return nil unless @protoc_cli
        path = @compiler.resolve(name)
        path && ::File.binread(path)
      end

      # @return [Schema::File, nil]
      def load(name, direct: false)
        return @done[name] if @done.key?(name)
        if direct && !@protoc_cli && @pool.include?(name)
          ast = Parser.new(read(name).to_s).parse(name)
          report(name, ast.position(:other), "A file with this name is already in the pool.")
          return @done[name] = nil
        end
        if (existing = @pool.file(name))
          list(existing)
          return @done[name] = existing
        end

        if (from = @pending.index { |n, _| n == name })
          chain = @pending[from..].map(&:first) + [name]
          ast = @pending[from][1]
          import = (from < @pending.size - 1) ? @pending[from + 1][0] : name
          report(name, ast.import_positions[import], "File recursively imports itself: #{chain.join(" -> ")}")
          return nil
        end

        source = read(name)
        unless source
          report(name, nil, "File not found.") if @protoc_cli
          return @done[name] = nil
        end

        parser = Parser.new(source)
        ast = parser.parse(name)
        parser.errors.each { |line, column, message| report(name, [line, column], message) }
        parser.warnings.each { |line, column, message| report(name, [line, column], message, :warning) }
        return @done[name] = nil unless parser.errors.empty?

        @pending << [name, ast]
        missing = []
        (ast.dependency + ast.option_dependency).each do |dep|
          missing << dep if load(dep).nil?
        end
        @pending.pop
        # protoc's BuildFile gives up quietly on a file that imports itself,
        # once the recursion has been reported
        return @done[name] = nil if ast.dependency.include?(name)

        linker = Linker.new(ast, pool: @pool, missing: missing, direct: (direct || @all_direct) && @protoc_cli,
          options_fallback: ->(type) { @compiler.builtin_options_type(type) }, source_info: @source_info,
          protoc_cli: @protoc_cli)
        linker.link
        Validator.new(linker).validate
        linker.problems.each do |problem|
          position = if problem.location == :import
            ast.import_positions[problem.import]
          else
            problem.node&.position(problem.location)
          end
          report(name, position, problem.message, problem.severity, spans: spans(ast, problem, position))
        end
        file = linker.errors? ? nil : linker.file
        file = add_to_pool(name, file) if file
        if file
          @linkers[name] = linker
          list(file)
        end
        @done[name] = file
      end
    end
  end
end
