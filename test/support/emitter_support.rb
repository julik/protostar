# frozen_string_literal: true

require "rbconfig"
require "monitor"

# Compiles corpus goldens, writes their native `_pb.rb` files, and loads them
# in fresh Ruby processes. Goldens that can share a process (no file name,
# symbol or constant defined differently) are loaded together.
module EmitterSupport
  LOADER = File.expand_path("../emitters/generated_loader.rb", __dir__)
  Emitters = Protostar::Compiler::Emitters

  # One compiled golden: the files of its set with source info, and the same
  # files rebuilt without it
  Compiled = Struct.new(:rel, :files, :bare, :compiler)

  @compiled = {}
  @answers = {}
  @mutex = Monitor.new

  class << self
    # @return [Compiled]
    def compiled(rel)
      @mutex.synchronize { @compiled[rel] ||= compile(rel) }
    end

    # The bare (source-info-free) copy of a file
    def bare(file, pool)
      pool.file(file.name) || pool.add(Protostar::Schema::Draft.copy(file, pool: pool, source_info: nil) do |d|
        d.options if d.options.declared?
      end)
    end

    # What a fresh process loaded for the golden's files
    def loaded(rel)
      @mutex.synchronize do
        @answers[rel] ||= begin
          bucket = buckets.find { |b| b.include?(rel) }
          answer = run(bucket)
          bucket.each { |r| @answers[r] = answer }
          answer
        end
      end
    end

    # Ruby module paths of the bootstrap files
    def namespaces
      @namespaces ||= begin
        compiler = Protostar::Compiler.new
        files = compiler.compile(Emitters::BOOTSTRAP)
        files.to_h { |f| [f.name, "Protostar::" + Emitters::Naming.module_path(f).join("::")] }
      end
    end

    def emitter
      Emitters::Ruby.new
    end

    # A value with NaNs replaced by their bits, so that equal descriptors compare equal
    def comparable(value)
      case value
      when Hash then value.to_h { |k, v| [k, comparable(v)] }
      when Array then value.map { |v| comparable(v) }
      when Float then value.nan? ? [:nan, [value].pack("G")] : value
      else value
      end
    end

    private

    def compile(rel)
      compiler = CompilerSupport.compiler
      files = compiler.compile([rel], source_info: true)
      pool = Protostar::Schema::Pool.new
      Compiled.new(rel, files, files.map { |f| bare(f, pool) }, compiler)
    end

    def buckets
      @buckets ||= begin
        list = []
        CompilerSupport.goldens.each do |rel|
          set = compiled(rel)
          bucket = list.find { |b| compatible?(b, set) }
          bucket ||= (list << {rels: [], files: {}, symbols: {}, constants: {}}).last
          add(bucket, set)
        end
        list.map { |b| b[:rels] }
      end
    end

    def compatible?(bucket, set)
      set.bare.all? do |file|
        known = bucket[:files][file.name]
        next known == file.serialize if known
        file.symbols.keys.none? { |s| bucket[:symbols].key?(s) } &&
          constants(file).none? { |c| bucket[:constants].key?(c) }
      end
    end

    def add(bucket, set)
      bucket[:rels] << set.rel
      set.bare.each do |file|
        next if bucket[:files].key?(file.name)
        bucket[:files][file.name] = file.serialize
        file.symbols.each_key { |s| bucket[:symbols][s] = true }
        constants(file).each { |c| bucket[:constants][c] = true }
      end
    end

    def constants(file)
      mods = Emitters::Naming.module_path(file, namespaces[file.name])
      (file.all_messages.reject(&:map_entry?) + file.all_enums).map do |d|
        (mods + [Emitters::Naming.relative_constant(d)]).join("::")
      end
    end

    def run(rels)
      TestSupport.tmpdir("protostar-emit") do |dir|
        names = []
        rels.each do |rel|
          compiled(rel).files.each do |file|
            next if names.include?(file.name)
            names << file.name
            next if Emitters::BOOTSTRAP.include?(file.name)
            path = File.join(dir, Emitters::Naming.require_name(file.name) + ".rb")
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, emitter.file(file))
          end
        end
        request = File.join(dir, "request.bin")
        File.binwrite(request, Marshal.dump({targets: names, files: names, namespaces: namespaces}))
        out = IO.popen([RbConfig.ruby, LOADER, dir, request], "rb", err: [:child, :out], &:read)
        raise "loader failed:\n#{out}" unless $?.success?
        Marshal.load(out) # rubocop:disable Security/MarshalLoad
      end
    end
  end
end
