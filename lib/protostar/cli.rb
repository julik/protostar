# frozen_string_literal: true

require "optparse"
require "fileutils"
require "protostar"

module Protostar
  # `protostar compile`, with protoc's flag names and protoc's messages
  #
  #   protostar compile -I proto --ruby_out=lib --grpc_out=lib acme/service.proto
  class CLI
    USAGE = "Usage: protostar compile [OPTION] PROTO_FILES\n       protostar --version"
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

    # @param argv [Array<String>]
    # @param out [IO]
    # @param err [IO]
    # @return [Integer] the exit status
    def self.run(argv, out: $stdout, err: $stderr)
      new(out, err).run(argv)
    end

    def initialize(out, err)
      @out = out
      @err = err
    end

    # @return [Integer]
    def run(argv)
      argv = argv.dup
      case argv.first
      when "--version", "-v"
        @out.puts "protostar #{VERSION}"
        0
      when "--help", "-h", nil
        @out.puts USAGE, "", parser({}).summarize
        argv.empty? ? 1 : 0
      when "compile"
        argv.shift
        compile(argv)
      else
        @err.puts "Unknown command: #{argv.first}", USAGE
        1
      end
    rescue Failure => e
      @err.write(e.message)
      @err.write("\n") unless e.message.end_with?("\n")
      1
    end

    private

    def parser(opts)
      OptionParser.new do |o|
        o.banner = USAGE
        o.on("-I", "--proto_path=PATH", "Directory to search for imports; repeatable, or colon-separated") do |v|
          (opts[:include] ||= []).concat(v.split(":"))
        end
        o.on("--ruby_out=DIR", "Write protostar's native Ruby (*_pb.rb)") { |v| opts[:ruby] = v }
        o.on("--google_out=DIR", "Write protoc's google-protobuf Ruby (*_pb.rb)") { |v| opts[:google] = v }
        o.on("--rbs_out=DIR", "Write RBS signatures (*_pb.rbs)") { |v| opts[:rbs] = v }
        o.on("--grpc_out=DIR", "Write gRPC service stubs (*_services_pb.rb)") { |v| opts[:grpc] = v }
        o.on("--descriptor_set_out=FILE", "Write a FileDescriptorSet") { |v| opts[:descriptor_set] = v }
        o.on("--include_imports", "With --descriptor_set_out, include every import") { opts[:include_imports] = true }
        o.on("--include_source_info", "With --descriptor_set_out, keep source info") { opts[:include_source_info] = true }
        o.on("--error_format=FORMAT", "gcc (default) or msvs") { |v| opts[:error_format] = v }
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
      raise Failure, "Unknown error format: #{format}" unless %w[gcc msvs].include?(format)
      @format = format.to_sym
      outputs = %i[ruby google rbs grpc descriptor_set].select { |k| opts[k] }
      raise Failure, "Missing output directives." if outputs.empty?
      raise Failure, "Missing input file." if files.empty?
      include = opts[:include] || ["."]
      compiler = Compiler.new(include_paths: include)
      names = files.map { |f| virtual_name(f, include, compiler) }
      compiled = begin
        compiler.compile(names, source_info: true)
      rescue Compiler::Error => e
        raise Failure, e.diagnostics.map { |d| d.format(@format) }.join("\n")
      end
      compiler.diagnostics.each { |d| @err.puts d.format(@format) }
      named = names.map { |n| compiled.find { |f| f.name == n } }.uniq
      written = generate(opts, named, compiled, compiler)
      written.each do |path, content|
        FileUtils.mkdir_p(::File.dirname(path))
        ::File.binwrite(path, content)
      end
      0
    end

    # Every output, generated before anything is written, as protoc does
    def generate(opts, named, compiled, compiler)
      written = {}
      %i[ruby google rbs grpc].each do |kind|
        next unless (dir = opts[kind])
        check_dir(dir)
        flag = "--#{kind}_out"
        named.each do |file|
          if kind == :rbs && file.syntax == :editions
            raise Failure, "#{file.name}: #{RBS_EDITIONS}--rbs_out: "
          end
          begin
            emitter(kind, compiler).emit([file]).each { |path, content| written[::File.join(dir, path)] = content }
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

    def emitter(kind, compiler)
      case kind
      when :ruby then Emitters::Ruby.new
      when :google then Emitters::GoogleRuby.new(pool: compiler.pool)
      when :rbs then Emitters::Rbs.new
      when :grpc then Emitters::Grpc.new
      end
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
