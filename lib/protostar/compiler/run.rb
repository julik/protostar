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

      def initialize(compiler, names, source_info)
        @compiler = compiler
        @pool = compiler.pool
        @names = names
        @source_info = source_info
        @diagnostics = []
        @pending = []
        @done = {}
        @failed = false
        @order = []
        @listed = {}
      end

      def failed?
        @failed || @diagnostics.any?(&:error?)
      end

      # @return [Array<Schema::File>]
      def call
        built = []
        @names.each do |name|
          file = load(name, direct: true)
          if file.nil?
            @failed = true
            break
          end
          built << [name, file]
        end
        unless failed?
          built.each { |_, file| Validator.cli_checks(file, @compiler, self) if @linkers[file] }
        end
        @order
      end

      # Records a diagnostic with a 0-based position (nil for none)
      def report(file, position, message, severity = :error)
        line, column = position
        line = nil if line && line < 0
        @diagnostics << Diagnostic.new(file, line && line + 1, line && column + 1, message, severity)
      end

      # @return [Linker, nil] the linker that built a file in this run
      def linker_for(file)
        @linkers&.[](file)
      end

      private

      def list(file)
        return if @listed[file.name]
        file.dependency_files.each { |dep| list(dep) }
        @listed[file.name] = true
        @order << file
      end

      # @return [Schema::File, nil]
      def load(name, direct: false)
        return @done[name] if @done.key?(name)
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

        path = @compiler.resolve(name)
        unless path
          report(name, nil, "File not found.")
          return @done[name] = nil
        end

        parser = Parser.new(::File.binread(path))
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

        linker = Linker.new(ast, pool: @pool, missing: missing, direct: direct,
          options_fallback: ->(type) { @compiler.builtin_options_type(type) }, source_info: @source_info)
        linker.link
        Validator.new(linker).validate if linker.file
        linker.problems.each do |problem|
          position = if problem.location == :import
            ast.import_positions[problem.import]
          else
            problem.node&.position(problem.location)
          end
          report(name, position, problem.message, problem.severity)
        end
        file = linker.errors? ? nil : linker.file
        if file
          @pool.add(file)
          (@linkers ||= {}.compare_by_identity)[file] = linker
          list(file)
        end
        @done[name] = file
      end
    end
  end
end
