# frozen_string_literal: true

require "optparse"
require "fileutils"
require "protostar"

module Protostar
  # `protostar compile`, with protoc's flag names and protoc's messages
  #
  # ```sh
  # protostar compile -I proto --ruby_out=lib --grpc_out=lib acme/service.proto
  # ```
  #
  # `compile` is the default command. Without `-I` every input's own directory
  # is an include path, and one input with no `--*_out` prints its native Ruby:
  #
  # ```sh
  # protostar proto/acme/person.proto > person_pb.rb
  # ```
  class CLI
    USAGE = "Usage: protostar [compile] [OPTION] PROTO_FILES\n       protostar lint [OPTION] PROTO_FILES_OR_DIRS\n" \
      "       protostar --version"
    DEFAULTS = "Without -I, the directory of each PROTO_FILE is an include path and the file is named by its\n" \
      "basename. With one PROTO_FILE and no --*_out, what --ruby_out would write is printed to stdout.\n" \
      "--ruby_out also writes RBS (*_pb.rbs) and Sorbet RBI (*_pb.rbi) next to each *_pb.rb; --no-rbs and\n" \
      "--no-rbi turn that off, --rbs_out and --rbi_out write them elsewhere."
    NO_STDIN = "Reading a .proto from stdin (-) is not supported; pass the file's path."
    Emitters = Compiler::Emitters
    RBS_EDITIONS = "is an editions file, but code generator --rbs_out hasn't been updated to support editions yet.  " \
      "Please ask the owner of this code generator to add support or switch back to proto2/proto3.\n\n" \
      "See https://protobuf.dev/editions/overview/ for more information."
    NO_MAPPING = "File does not reside within any path specified using --proto_path (or -I).  You must specify a " \
      "--proto_path which encompasses this file.  Note that the proto_path must be an exact prefix of the .proto " \
      "file names -- protoc is too dumb to figure out when two paths (e.g. absolute and relative) are equivalent " \
      "(it's harder than you think)."

    # Raised to stop with a message on stderr and exit status 1
    class Failure < Protostar::Error; end

    # Returns the exit status.
    #: (Array[String] argv, ?out: IO, ?err: IO) -> Integer
    def self.run(argv, out: $stdout, err: $stderr)
      new(out, err).run(argv)
    end

    # Whether to colour what goes to `io`: a terminal, and NO_COLOR unset
    def self.color?(io) # :nodoc:
      io.respond_to?(:tty?) && io.tty? && ENV.fetch("NO_COLOR", "").empty?
    end

    def initialize(out, err)
      @out = out
      @err = err
    end

    #: (untyped argv) -> Integer
    def run(argv)
      argv = argv.dup
      case argv.first
      when "--version", "-v"
        @out.puts "protostar #{VERSION}"
        0
      when "--help", "-h", nil
        @out.puts USAGE, "", DEFAULTS, "", parser({}).summarize
        argv.empty? ? 1 : 0
      when "compile"
        argv.shift
        compile(argv)
      when "lint"
        argv.shift
        Lint::Command.new(@out, @err).run(argv)
      else
        return compile(argv) unless command?(argv.first)
        @err.puts "Unknown command: #{argv.first}", USAGE
        1
      end
    rescue Failure => e
      @err.write(e.message)
      @err.write("\n") unless e.message.end_with?("\n")
      1
    end

    private

    # A bare word that is not a file is a mistyped command, not a missing input
    def command?(arg)
      !arg.start_with?("-") && !arg.end_with?(".proto") && !::File.exist?(arg)
    end

    def parser(opts)
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("-I", "--proto_path=PATH", "Directory to search for imports; repeatable, or colon-separated") do |v|
          (opts[:include] ||= []).concat(v.split(":"))
        end
        o.on("--ruby_out=DIR", "Write protostar's native Ruby (*_pb.rb)") { |v| opts[:ruby] = v }
        o.on("--google_out=DIR", "Write protoc's google-protobuf Ruby (*_pb.rb)") { |v| opts[:google] = v }
        o.on("--rbs_out=DIR", "Write RBS signatures (*_pb.rbs): for protostar's classes with --ruby_out, else protoc's") { |v| opts[:rbs] = v }
        o.on("--rbi_out=DIR", "Write Sorbet RBI (*_pb.rbi): for protostar's classes with --ruby_out, else google-protobuf's") { |v| opts[:rbi] = v }
        o.on("--no-rbs", "With --ruby_out, write no *_pb.rbs next to each *_pb.rb") { opts[:no_rbs] = true }
        o.on("--no-rbi", "With --ruby_out, write no *_pb.rbi next to each *_pb.rb") { opts[:no_rbi] = true }
        o.on("--grpc_out=DIR", "Write gRPC service stubs (*_services_pb.rb)") { |v| opts[:grpc] = v }
        o.on("--descriptor_set_out=FILE", "Write a FileDescriptorSet") { |v| opts[:descriptor_set] = v }
        o.on("--include_imports", "With --descriptor_set_out, include every import") { opts[:include_imports] = true }
        o.on("--include_source_info", "With --descriptor_set_out, keep source info") { opts[:include_source_info] = true }
        o.on("--error_format=FORMAT", "gcc (default), msvs, or rich: rustc-style, with the source and a fix") do |v|
          opts[:error_format] = v
        end
      end
    end

    def compile(argv)
      opts = {}
      files = begin
        parser(opts).parse(argv)
      rescue OptionParser::ParseError => e
        raise Failure, e.message
      end
      format = opts.fetch(:error_format, "gcc")
      raise Failure, "Unknown error format: #{format}" unless %w[gcc msvs rich].include?(format)
      @format = format.to_sym
      raise Failure, NO_STDIN if files.include?("-")
      raise Failure, "Missing input file." if files.empty?
      sidecars(opts)
      outputs = %i[ruby google rbs rbi grpc descriptor_set].select { |k| opts[k] }
      if outputs.empty?
        raise Failure, "--include_imports writes a set of files; add --descriptor_set_out=FILE." if opts[:include_imports]
        raise Failure, "#{files.size} files cannot share stdout; add --ruby_out=DIR to write a _pb.rb for each." if files.size > 1
      end
      include = opts[:include] || default_include(files)
      compiler = Compiler.new(include_paths: include)
      names = files.map { |f| opts[:include] ? virtual_name(f, include, compiler) : default_name(f, include, compiler) }
      compiled = begin
        compiler.compile(names, source_info: true)
      rescue Compiler::Error => e
        lines = e.diagnostics.map { |d| show(d, compiler) }
        lines.concat(import_hints(e.diagnostics, include)) unless opts[:include]
        raise Failure, lines.join("\n")
      end
      compiler.diagnostics.each { |d| @err.puts show(d, compiler) }
      named = names.map { |n| compiled.find { |f| f.name == n } }.uniq
      return print_ruby(named.first) if outputs.empty?
      written = generate(opts, named, compiled, compiler)
      written.each do |path, content|
        FileUtils.mkdir_p(::File.dirname(path))
        ::File.binwrite(path, content)
      end
      0
    end

    # Next to --ruby_out, protostar's own signatures go beside the Ruby unless
    # declined or sent elsewhere. --google_out writes only what protoc writes.
    def sidecars(opts)
      %i[rbs rbi].each do |kind|
        no = :"no_#{kind}"
        raise Failure, "--#{kind}_out and --no-#{kind} contradict each other." if opts[kind] && opts[no]
        opts[kind] ||= opts[:ruby] if native_rbs?(opts) && !opts[no]
      end
    end

    # protoc's one line, or with --error_format=rich, rustc's several
    def show(diagnostic, compiler)
      return diagnostic.format(@format) unless @format == :rich
      @renderer ||= Diagnostics::Renderer.new(color: CLI.color?(@err),
        source: ->(d) { (path = compiler.resolve(d.file)) && ::File.binread(path) })
      @renderer.render(diagnostic)
    end

    def print_ruby(file)
      @out.write(Emitters::Ruby.new.file(file))
      0
    rescue Emitters::Error => e
      raise Failure, "#{file.name}: #{e.message}"
    end

    # The directories of the inputs on disk, in the order given. Each input is
    # named by its basename then, so two inputs of one name cannot both be
    def default_include(files)
      seen = {}
      files.select { |f| ::File.file?(f) }.map do |f|
        other = seen[::File.basename(f)] ||= f
        unless ::File.expand_path(other) == ::File.expand_path(f)
          raise Failure, "#{other} and #{f} are both #{::File.basename(f)}; pass -I with a directory above both to tell them apart."
        end
        ::File.dirname(f)
      end.uniq { |dir| ::File.expand_path(dir) }
    end

    def default_name(arg, include, compiler)
      return virtual_name(arg, include, compiler) unless ::File.file?(arg)
      name = ::File.basename(arg)
      found = compiler.resolve(name)
      return name if found == ::File.expand_path(arg)
      raise Failure, "#{arg}: Input is shadowed by #{shorten(found)}, which is next to another input. Pass -I to choose one."
    end

    # An import not found, but one directory above an input's, was most
    # likely meant relative to that parent
    def import_hints(diagnostics, include)
      missing = diagnostics.select { |d| d.line.nil? && d.message == "File not found." }.map(&:file).uniq
      missing.filter_map do |name|
        parent = include.map { |dir| ::File.dirname(::File.expand_path(dir)) }
          .find { |dir| ::File.file?(::File.join(dir, name)) }
        next unless parent
        shown = shorten(parent)
        "#{name} is in #{shown}/, which is not an include path. Add -I #{shown} to find it there."
      end
    end

    def shorten(dir)
      cwd = ::Dir.pwd
      return "." if dir == cwd
      dir.delete_prefix("#{cwd}/")
    end

    # Every output, generated before anything is written, as protoc does
    def generate(opts, named, compiled, compiler)
      written = {}
      %i[ruby google rbs rbi grpc].each do |kind|
        next unless (dir = opts[kind])
        check_dir(dir)
        flag = "--#{kind}_out"
        named.each do |file|
          if kind == :rbs && file.syntax == :editions && !native_rbs?(opts)
            raise Failure, "#{file.name}: #{RBS_EDITIONS}--rbs_out: "
          end
          begin
            emitter(kind, compiler, opts).emit([file]).each { |path, content| written[::File.join(dir, path)] = content }
          rescue Emitters::Error => e
            raise Failure, "#{flag}: #{file.name}: #{e.message}"
          end
        end
      end
      if (path = opts[:descriptor_set])
        set = Emitters::DescriptorSet.new(include_imports: opts[:include_imports],
          include_source_info: opts[:include_source_info], pool: compiler.pool)
        written[path] = set.emit(named, available: compiled)
      end
      written
    end

    def emitter(kind, compiler, opts)
      case kind
      when :ruby then Emitters::Ruby.new
      when :google then Emitters::GoogleRuby.new(pool: compiler.pool)
      when :rbs then native_rbs?(opts) ? Emitters::ProtostarRbs.new : Emitters::Rbs.new
      when :rbi then native_rbs?(opts) ? Emitters::ProtostarRbi.new : Emitters::Rbi.new
      when :grpc then Emitters::Grpc.new
      end
    end

    # --rbs_out and --rbi_out describe protostar's classes next to --ruby_out,
    # and google-protobuf's otherwise
    def native_rbs?(opts)
      opts[:ruby] && !opts[:google]
    end

    def check_dir(dir)
      raise Failure, "#{dir}/: No such file or directory" unless ::File.directory?(dir)
    end

    # protoc's MakeInputsBeProtoPathRelative: a file argument is a path on
    # disk under an include path, or else a name relative to one
    def virtual_name(arg, include, compiler)
      unless ::File.exist?(arg)
        return arg if compiler.resolve(arg)
        raise Failure, "Could not make proto path relative: #{arg}: No such file or directory"
      end
      mapped = disk_to_virtual(arg, include)
      return mapped if mapped
      return arg if compiler.resolve(arg)
      raise Failure, "#{arg}: #{NO_MAPPING}"
    end

    def disk_to_virtual(arg, include)
      path = Compiler.canonical_path(arg)
      include.each do |dir|
        dir = Compiler.canonical_path(dir)
        return path if dir.empty? && !path.start_with?("/")
        return path.delete_prefix("#{dir}/") if path.start_with?("#{dir}/")
      end
      nil
    end
  end
end
