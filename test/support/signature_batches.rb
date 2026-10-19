# frozen_string_literal: true

# The corpus files whose signatures get checked by an external tool (rbs,
# sorbet), grouped so that no two files in a group declare the same constant
module SignatureBatches
  Emitters = Protostar::Compiler::Emitters

  module_function

  # @return [Hash{String => Protostar::Schema::File}] every corpus file and its imports, by name
  def corpus_files(bootstrap: false)
    files = {}
    CodecFixtures.goldens.each do |rel|
      SchemaFixtures.cached(rel)[0].files.each do |f|
        files[f.name] ||= f if bootstrap || !Emitters::BOOTSTRAP.include?(f.name)
      end
    end
    files
  end

  # Groups of files, each with its imports, in which no two files declare the same name
  def batches(files)
    closure = lambda do |f, acc = {}|
      next acc if acc[f.name] || !files.key?(f.name)
      acc[f.name] = f
      f.dependencies.each { |d| closure.call(files[d], acc) if files[d] }
      acc
    end
    declared = lambda do |f|
      prefix = Emitters::Naming.module_path(f).join("::")
      (f.all_messages + f.all_enums).map { |d| "#{prefix}::#{Emitters::Naming.relative_constant(d)}" }
    end
    batches = []
    files.each_value do |f|
      group = closure.call(f)
      batch = batches.find do |b|
        group.all? { |name, g| b[:files][name] || declared.call(g).none? { |n| b[:names][n] } }
      end
      batch ||= (batches << {files: {}, names: {}}).last
      group.each do |name, g|
        next if batch[:files][name]
        batch[:files][name] = g
        declared.call(g).each { |n| batch[:names][n] = true }
      end
    end
    batches.map { |b| b[:files] }
  end

  # Writes what the emitter makes of each file under dir
  def write(dir, files, emitter)
    files.each_value do |f|
      emitter.emit([f]).each do |path, content|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), content)
      end
    end
  end
end
