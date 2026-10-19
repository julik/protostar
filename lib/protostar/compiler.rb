# frozen_string_literal: true

module Protostar
  # A pure-Ruby protoc front end: turns `.proto` source into
  # Protostar::Schema::Files whose `to_proto` is what protoc 36.2 puts in a
  # `FileDescriptorProto`, and rejects what protoc rejects with protoc's
  # `file:line:col: message` diagnostics.
  #
  # ```ruby
  # compiler = Protostar::Compiler.new(include_paths: ["proto"])
  # files = compiler.compile(["foo/bar.proto"], source_info: true)
  # ```
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
    # protoc reports none). #to_s and #format print it as protoc does; the
    # rest is for Diagnostics::Renderer, which prints it as rustc would.
    class Diagnostic
      # The file name as imported.
      attr_reader :file #: String
      attr_reader :line #: Integer?
      attr_reader :column #: Integer?
      attr_reader :message #: String
      # :error or :warning.
      attr_reader :severity #: :error | :warning
      # The file on disk, spelled as protoc prints it: the include
      # path as given (canonicalized) joined with #file; nil for in-memory and bundled files.
      attr_reader :path #: String?
      # The primary span first, then related ones; empty
      # when the compiler knows only #line and #column, or nothing.
      attr_reader :spans #: Array[Diagnostics::Span]
      # `help:` lines, the concrete fix in words.
      attr_reader :help #: Array[String]
      # `note:` lines.
      attr_reader :notes #: Array[String]
      # A mechanical fix `protostar lint --fix` can apply.
      attr_reader :fix #: Diagnostics::Fix?
      # The lint rule that found it, e.g. "FIELD_NOT_REQUIRED".
      attr_reader :rule #: String?

      #: (String file, Integer? line, Integer? column, String message, ?(:error | :warning) severity, ?path: String?, ?spans: Array[Diagnostics::Span], ?code: String?, ?title: String?, ?help: Array[String], ?notes: Array[String], ?fix: Diagnostics::Fix?, ?rule: String?) -> void
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

      # Returns the stable code `protostar lint --explain` knows, e.g. "L0201";
      # for the compiler's messages, looked up in Diagnostics::Codes.
      #: () -> String?
      def code
        @code || Diagnostics::Codes.lookup(@message)&.code
      end

      # Returns the headline the renderer prints: a short rewording where the
      # catalogue has one, else #message.
      #: () -> String
      def title
        @title || @message
      end

      # Returns a copy with what Diagnostics::Codes knows about the message
      # filled in: code, title, span labels, help and notes.
      #: () -> Diagnostic
      def annotated
        @code ? self : Diagnostics::Codes.annotate(self)
      end

      # Returns a copy with the given attributes replaced.
      #: (**untyped changes) -> Diagnostic
      def with(**changes)
        attrs = {path: @path, spans: @spans, code: @code, title: @title, help: @help, notes: @notes, fix: @fix,
                 rule: @rule}.merge(changes)
        Diagnostic.new(@file, @line, @column, @message, @severity, **attrs)
      end

      #: () -> bool
      def error?
        @severity == :error
      end

      #: () -> bool
      def warning?
        @severity == :warning
      end

      # Returns the diagnostic as protoc prints it, with the virtual file name.
      #: () -> String
      def to_s
        location = @line ? "#{@file}:#{@line}:#{@column}" : @file
        warning? ? "#{location}: warning: #{@message}" : "#{location}: #{@message}"
      end

      # - `error_format`: :gcc or :msvs, protoc's `--error_format`
      #
      # Returns the diagnostic as protoc's command line prints it: the path on disk when known.
      #: (?:gcc | :msvs error_format) -> String
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
      # Every error found, in protoc's order.
      attr_reader :diagnostics #: Array[Diagnostic]

      def initialize(diagnostics)
        @diagnostics = diagnostics.freeze
        super(diagnostics.join("\n"))
      end
    end

    # Where compiled files go and imports are looked up.
    attr_reader :pool #: Schema::Pool
    # Directories searched for imports, in order, before the bundled includes.
    attr_reader :include_paths #: Array[String]
    # Warnings (and errors) of the last #compile.
    attr_reader :diagnostics #: Array[Diagnostic]

    # - `include_paths`: directories to resolve `.proto` names against, in order
    # - `pool`: receives every compiled file; files already in it are reused
    # - `bundled_includes`: search the bundled `google/protobuf/*.proto` after `include_paths`
    #: (?include_paths: Array[String], ?pool: Schema::Pool, ?bundled_includes: bool) -> void
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
    # - `names`: file names relative to an include path, e.g. "foo/bar.proto"
    # - `source_info`: keep `source_code_info` in the built files
    # - `retain_options`: return the pool's files, source-retention options included
    # - `sources`: file contents by name, consulted before the include paths
    # - `protoc_cli`: @api private: false checks like a bare DescriptorPool rather than
    #   protoc's command line (no imports loaded from disk, no unused import, naming style or other
    #   command-line checks), as protoc's own parser tests do
    #
    # Returns the named files and their transitive imports, imports first.
    # Raises Error with every diagnostic when a file cannot be compiled.
    #: (Array[String] names, ?source_info: bool, ?retain_options: bool, ?sources: Hash[String, String], ?protoc_cli: bool) -> Array[Schema::File]
    def compile(names, source_info: false, retain_options: false, sources: {}, protoc_cli: true)
      run = Run.new(self, names, source_info, sources: sources, protoc_cli: protoc_cli)
      files = run.call
      @diagnostics = run.diagnostics
      raise Error.new(run.diagnostics) if run.failed?
      retain_options ? files : files.map { |f| output_file(f) }
    end

    # **Deprecated:** Goes away in 0.2.0. Use #compile and read the Schema::Files, or
    # `compile(names).map { |f| f.to_proto.to_h }` for the same Hashes.
    #
    # Same as #compile, each file as `to_proto.to_h`, for reading
    #: (untyped names, ?source_info: untyped, ?retain_options: untyped, ?sources: untyped) -> Array[Hash[untyped, untyped]]
    def compile_to_hashes(names, source_info: false, retain_options: false, sources: {})
      Protostar.deprecated("Compiler#compile_to_hashes", "compile(names).map { |f| f.to_proto.to_h }")
      compile(names, source_info: source_info, retain_options: retain_options, sources: sources).map(&:to_h)
    end

    # - `name`: a virtual file name
    #
    # Returns the path it resolves to on disk.
    #: (String name) -> String?
    def resolve(name)
      @include_paths.each do |dir|
        path = ::File.join(dir, name)
        return path if ::File.file?(path)
      end
      nil
    end

    # - `name`: a virtual file name
    #
    # Returns where it is on disk, spelled from the include path as it
    # was given, as protoc prints it in diagnostics; nil when not under one.
    #: (String name) -> String?
    def disk_path(name)
      @given_paths.each_with_index do |given, i|
        next unless ::File.file?(::File.join(@include_paths[i], name))
        return given.empty? ? name : "#{given}/#{name}"
      end
      nil
    end

    # protoc's CanonicalizePath: "." components, empty components and a
    # trailing slash dropped
    def self.canonical_path(path) # :nodoc:
      parts = path.split("/").reject { |p| p.empty? || p == "." }
      path.start_with?("/") ? "/#{parts.join("/")}" : parts.join("/")
    end

    # The options message protoc compiles into itself, from the bundled
    # descriptor.proto, for files that do not import descriptor.proto
    def builtin_options_type(name) # :nodoc:
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
    def self.simple_dtoa(value) # :nodoc:
      Schema::DefaultValue.simple_dtoa(value)
    end

    # protoc's SimpleFtoa over the float nearest to `value`
    def self.simple_ftoa(value) # :nodoc:
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
    def self.c_escape(bytes) # :nodoc:
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
