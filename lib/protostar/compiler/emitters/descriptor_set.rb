# frozen_string_literal: true

module Protostar
  class Compiler
    module Emitters
      # Writes a serialized `google.protobuf.FileDescriptorSet`, as protoc's
      # `--descriptor_set_out` does
      class DescriptorSet
        # @param include_imports [Boolean] also write every file the given ones import,
        #   dependencies first (`import option` files included, as protoc does)
        # @param include_source_info [Boolean] keep `source_code_info`
        # @param pool [Schema::Pool, nil] where `import option` files and their extensions are found
        def initialize(include_imports: false, include_source_info: false, pool: nil)
          @include_imports = include_imports
          @include_source_info = include_source_info
          @pool = pool
        end

        # @param files [Array<Schema::File>] the files named on the command line
        # @param available [Array<Schema::File>] files `import option` names are looked up in
        #   before the pool, such as everything {Compiler#compile} returned
        # @return [String] binary
        def emit(files, available: [])
          out = "".b
          w = Wire::Writer.new(out)
          @available = available.to_h { |f| [f.name, f] }
          ordered(files).each do |file|
            w.write_tag(1, Wire::LENGTH_DELIMITED)
            w.write_bytes(file.serialize(pool: @pool, source_info: @include_source_info))
          end
          out
        end

        private

        # protoc's GetTransitiveDependencies: depth first, each file after its imports
        def ordered(files)
          return files unless @include_imports
          seen = {}
          out = []
          visit = lambda do |file|
            next if seen[file.name]
            seen[file.name] = true
            file.dependency_files.each { |dep| visit.call(dep) }
            file.option_dependencies.each do |name|
              dep = @available[name] || @pool&.file(name)
              visit.call(dep) if dep
            end
            out << file
          end
          files.each { |f| visit.call(f) }
          out
        end
      end
    end
  end
end
