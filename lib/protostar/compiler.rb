# frozen_string_literal: true

module Protostar
  # A pure-Ruby protoc front end: turns `.proto` source into
  # {Protostar::Schema::File}s whose `to_h` matches what protoc 36.2 puts in a
  # `FileDescriptorProto`, and rejects what protoc rejects with protoc's
  # `file:line:col: message` diagnostics.
  #
  #   compiler = Protostar::Compiler.new(include_paths: ["proto"])
  #   files = compiler.compile(["foo/bar.proto"], source_info: true)
  class Compiler
    # Where the bundled `google/protobuf/*.proto` imports live
    INCLUDE_DIR = ::File.expand_path("compiler/include", __dir__)

    # One error or warning, with protoc's 1-based line and column (nil when
    # protoc reports none)
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

      def initialize(file, line, column, message, severity = :error)
        @file = file
        @line = line
        @column = column
        @message = message
        @severity = severity
        freeze
      end

      def error?
        @severity == :error
      end

      def warning?
        @severity == :warning
      end

      # @return [String] as protoc prints it
      def to_s
        location = @line ? "#{@file}:#{@line}:#{@column}" : @file
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
        super(diagnostics.map(&:to_s).join("\n"))
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

    # Same as {#compile}, as descriptor hashes
    # @return [Array<Hash>]
    def compile_to_hashes(names, source_info: false, retain_options: false, sources: {})
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
      type = @pool.find_message("google.protobuf.FileDescriptorProto") ||
        builtin_options_type("google.protobuf.FileDescriptorProto")
      extension = lambda do |name|
        found = @pool.find_symbol(name)
        found if found.is_a?(Schema::Field) && found.extension?
      end
      hash = Retention.strip(file.to_h, type, extension)
      @output.add(Schema::Builder.build(hash, pool: @output))
    end
    private :output_file

    # protoc's SimpleDtoa: the shortest of %.15g and %.17g that reads back exactly
    # @api private
    def self.simple_dtoa(value)
      return "inf" if value == Float::INFINITY
      return "-inf" if value == -Float::INFINITY
      return "nan" if value.nan?
      text = format("%.15g", value)
      text = format("%.17g", value) unless Float(text) == value
      text
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
        if (escaped = C_ESCAPES[b])
          out << escaped
        elsif b < 32 || b >= 127
          out << format("\\%03o", b)
        else
          out << b
        end
      end
      out
    end
  end
end

require_relative "compiler/lexer"
require_relative "compiler/ast"
require_relative "compiler/source_info"
require_relative "compiler/parser"
require_relative "compiler/symbol_table"
require_relative "compiler/linker"
require_relative "compiler/option_interpreter"
require_relative "compiler/text_format"
require_relative "compiler/validator"
require_relative "compiler/retention"
require_relative "compiler/run"
