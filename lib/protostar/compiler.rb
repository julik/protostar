# frozen_string_literal: true

module Protostar
  # A pure-Ruby protoc front end: turns `.proto` source into
  # {Protostar::Schema::File}s whose `to_proto` is what protoc 36.2 puts in a
  # `FileDescriptorProto`, and rejects what protoc rejects with protoc's
  # `file:line:col: message` diagnostics.
  #
  #   compiler = Protostar::Compiler.new(include_paths: ["proto"])
  #   files = compiler.compile(["foo/bar.proto"], source_info: true)
  class Compiler
    # Where the bundled `google/protobuf/*.proto` imports live
    INCLUDE_DIR = ::File.expand_path("compiler/include", __dir__)

    autoload :Lexer, ::File.expand_path("compiler/lexer", __dir__)
    autoload :AST, ::File.expand_path("compiler/ast", __dir__)
    autoload :SourceInfo, ::File.expand_path("compiler/source_info", __dir__)
    autoload :Parser, ::File.expand_path("compiler/parser", __dir__)
    autoload :SymbolTable, ::File.expand_path("compiler/symbol_table", __dir__)
    autoload :Linker, ::File.expand_path("compiler/linker", __dir__)
    autoload :OptionInterpreter, ::File.expand_path("compiler/option_interpreter", __dir__)
    autoload :TextFormat, ::File.expand_path("compiler/text_format", __dir__)
    autoload :Validator, ::File.expand_path("compiler/validator", __dir__)
    autoload :Retention, ::File.expand_path("compiler/retention", __dir__)
    autoload :Run, ::File.expand_path("compiler/run", __dir__)
    autoload :Emitters, ::File.expand_path("compiler/emitters", __dir__)

    # One error or warning, with protoc's 1-based line and column (nil when
    # protoc reports none). {#to_s} and {#format} print it as protoc does; the
    # rest is for {Diagnostics::Renderer}, which prints it as rustc would.
    class Diagnostic
      # @return [String] the file name as imported
      attr_reader :file
      # @return [Integer, nil]
      attr_reader :line
      # @return [Integer, nil]
      attr_reader :column
      # @return [String]
      attr_reader :message
      # @return [Symbol] :error or :warning
      attr_reader :severity
      # @return [String, nil] the file on disk, spelled as protoc prints it: the include
      #   path as given (canonicalized) joined with {#file}; nil for in-memory and bundled files
      attr_reader :path
      # @return [Array<Diagnostics::Span>] the primary span first, then related ones; empty
      #   when the compiler knows only {#line} and {#column}, or nothing
      attr_reader :spans
      # @return [Array<String>] `help:` lines, the concrete fix in words
      attr_reader :help
      # @return [Array<String>] `note:` lines
      attr_reader :notes
      # @return [Diagnostics::Fix, nil] a mechanical fix `protostar lint --fix` can apply
      attr_reader :fix
      # @return [String, nil] the lint rule that found it, e.g. "FIELD_NOT_REQUIRED"
      attr_reader :rule

      def initialize(file, line, column, message, severity = :error, path: nil, spans: [], code: nil, title: nil,
        help: [], notes: [], fix: nil, rule: nil)
        @file = file
        @line = line
        @column = column
        @message = message
        @severity = severity
        @path = path
        @spans = spans.freeze
        @code = code
        @title = title
        @help = help.freeze
        @notes = notes.freeze
        @fix = fix
        @rule = rule
        freeze
      end

      # @return [String, nil] the stable code `protostar lint --explain` knows, e.g. "L0201";
      #   for the compiler's messages, looked up in {Diagnostics::Codes}
      def code
        @code || Diagnostics::Codes.lookup(@message)&.code
      end

      # @return [String] the headline the renderer prints: a short rewording where the
      #   catalogue has one, else {#message}
      def title
        @title || @message
      end

      # @return [Diagnostic] a copy with what {Diagnostics::Codes} knows about the message
      #   filled in: code, title, span labels, help and notes
      def annotated
        @code ? self : Diagnostics::Codes.annotate(self)
      end

      # @return [Diagnostic] a copy with the given attributes replaced
      def with(**changes)
        attrs = {path: @path, spans: @spans, code: @code, title: @title, help: @help, notes: @notes, fix: @fix,
                 rule: @rule}.merge(changes)
        Diagnostic.new(@file, @line, @column, @message, @severity, **attrs)
      end

      def error?
        @severity == :error
      end

      def warning?
        @severity == :warning
      end

      # @return [String] as protoc prints it, with the virtual file name
      def to_s
        location = @line ? "#{@file}:#{@line}:#{@column}" : @file
        warning? ? "#{location}: warning: #{@message}" : "#{location}: #{@message}"
      end

      # @param error_format [Symbol] :gcc or :msvs, protoc's `--error_format`
      # @return [String] as protoc's command line prints it: the path on disk when known
      def format(error_format = :gcc)
        name = @path || @file
        location = if @line.nil?
          name
        elsif error_format == :msvs
          "#{name}(#{@line}) : #{@severity} in column=#{@column}"
        else
          "#{name}:#{@line}:#{@column}"
        end
        warning? ? "#{location}: warning: #{@message}" : "#{location}: #{@message}"
      end

      def ==(other)
        other.is_a?(Diagnostic) && other.to_s == to_s
      end
      alias_method :eql?, :==

      def hash
        to_s.hash
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end
    end

    # Raised when compilation fails
    class Error < Protostar::Error
      # @return [Array<Diagnostic>] every error found, in protoc's order
      attr_reader :diagnostics

      def initialize(diagnostics)
        @diagnostics = diagnostics.freeze
        super(diagnostics.join("\n"))
      end
    end

    # @return [Schema::Pool] where compiled files go and imports are looked up
    attr_reader :pool
    # @return [Array<String>] directories searched for imports, in order, before the bundled includes
    attr_reader :include_paths
    # @return [Array<Diagnostic>] warnings (and errors) of the last {#compile}
    attr_reader :diagnostics

    # @param include_paths [Array<String>] directories to resolve `.proto` names against, in order
    # @param pool [Schema::Pool] receives every compiled file; files already in it are reused
    # @param bundled_includes [Boolean] search the bundled `google/protobuf/*.proto` after `include_paths`
    def initialize(include_paths: [], pool: Schema::Pool.new, bundled_includes: true)
      @given_paths = include_paths.map { |p| Compiler.canonical_path(p) }.freeze
      @include_paths = include_paths.map { |p| ::File.expand_path(p) }.freeze
      @include_paths += [INCLUDE_DIR] if bundled_includes
      @pool = pool
      @diagnostics = []
    end

    # Compiles `.proto` files and everything they import.
    #
    # The pool keeps every option, as protoc's own pool does, so later files
    # are validated against the full declarations. What is returned is what
    # protoc writes with `--descriptor_set_out`: options declared
    # `retention = RETENTION_SOURCE` removed (pass `retain_options: true`
    # for the pool's files as they are).
    #
    # @param names [Array<String>] file names relative to an include path, e.g. "foo/bar.proto"
    # @param source_info [Boolean] keep `source_code_info` in the built files
    # @param retain_options [Boolean] return the pool's files, source-retention options included
    # @param sources [Hash{String => String}] file contents by name, consulted before the include paths
    # @param protoc_cli [Boolean] @api private: false checks like a bare DescriptorPool rather than
    #   protoc's command line (no imports loaded from disk, no unused import, naming style or other
    #   command-line checks), as protoc's own parser tests do
    # @return [Array<Schema::File>] the named files and their transitive imports, imports first
    # @raise [Error] with every diagnostic when a file cannot be compiled
    def compile(names, source_info: false, retain_options: false, sources: {}, protoc_cli: true)
      run = Run.new(self, names, source_info, sources: sources, protoc_cli: protoc_cli)
      files = run.call
      @diagnostics = run.diagnostics
      raise Error.new(run.diagnostics) if run.failed?
      retain_options ? files : files.map { |f| output_file(f) }
    end

    # Same as {#compile}, each file as `to_proto.to_h`, for reading
    # @deprecated Goes away in 0.2.0. Use {#compile} and read the {Schema::File}s, or
    #   `compile(names).map { |f| f.to_proto.to_h }` for the same Hashes.
    # @return [Array<Hash>]
    def compile_to_hashes(names, source_info: false, retain_options: false, sources: {})
      Protostar.deprecated("Compiler#compile_to_hashes", "compile(names).map { |f| f.to_proto.to_h }")
      compile(names, source_info: source_info, retain_options: retain_options, sources: sources).map(&:to_h)
    end

    # @param name [String] a virtual file name
    # @return [String, nil] the path it resolves to on disk
    def resolve(name)
      @include_paths.each do |dir|
        path = ::File.join(dir, name)
        return path if ::File.file?(path)
      end
      nil
    end

    # @param name [String] a virtual file name
    # @return [String, nil] where it is on disk, spelled from the include path as it
    #   was given, as protoc prints it in diagnostics; nil when not under one
    def disk_path(name)
      @given_paths.each_with_index do |given, i|
        next unless ::File.file?(::File.join(@include_paths[i], name))
        return given.empty? ? name : "#{given}/#{name}"
      end
      nil
    end

    # protoc's CanonicalizePath: "." components, empty components and a
    # trailing slash dropped
    # @api private
    def self.canonical_path(path)
      parts = path.split("/").reject { |p| p.empty? || p == "." }
      path.start_with?("/") ? "/#{parts.join("/")}" : parts.join("/")
    end

    # The options message protoc compiles into itself, from the bundled
    # descriptor.proto, for files that do not import descriptor.proto
    # @api private
    def builtin_options_type(name)
      @builtin ||= begin
        builtin = Compiler.new(include_paths: [], pool: Schema::Pool.new)
        builtin.compile(["google/protobuf/descriptor.proto"]).last
      end
      @builtin.find_message(name)
    end

    # The source-retention-stripped copy of a pool file, linked against the
    # stripped copies of its imports
    def output_file(file)
      @output ||= Schema::Pool.new
      existing = @output.file(file.name)
      return existing if existing
      file.dependency_files.each { |dep| output_file(dep) }
      options_type = ->(name) { @pool.find_message(name) || builtin_options_type(name) }
      @output.add(Retention.strip(file, @output, options_type), warn: false)
    end
    private :output_file

    # protoc's SimpleDtoa: the shortest of %.15g and %.17g that reads back exactly
    # @api private
    def self.simple_dtoa(value)
      Schema::DefaultValue.simple_dtoa(value)
    end

    # protoc's SimpleFtoa over the float nearest to `value`
    # @api private
    def self.simple_ftoa(value)
      return "inf" if value == Float::INFINITY
      return "-inf" if value == -Float::INFINITY
      return "nan" if value.nan?
      single = [value].pack("e").unpack1("e")
      text = format("%.6g", single)
      parsed = Float(text)
      unless parsed.finite? && [parsed].pack("e").unpack1("e") == single && strtof_in_range?(parsed)
        text = format("%.9g", single)
      end
      text
    end

    # strtof reports ERANGE for values that overflow or flush to zero
    def self.strtof_in_range?(value)
      return true if value == 0.0
      single = [value].pack("e").unpack1("e")
      single.finite? && single.abs >= 1.1754943508222875e-38
    end
    private_class_method :strtof_in_range?

    C_ESCAPES = {10 => "\\n", 13 => "\\r", 9 => "\\t", 34 => "\\\"", 39 => "\\'", 92 => "\\\\"}.freeze

    # absl::CEscape: protoc's spelling of bytes defaults
    # @api private
    def self.c_escape(bytes)
      out = +""
      bytes.each_byte do |b|
        out << if (escaped = C_ESCAPES[b])
          escaped
        elsif b < 32 || b >= 127
          format("\\%03o", b)
        else
          b
        end
      end
      out
    end
  end
end
