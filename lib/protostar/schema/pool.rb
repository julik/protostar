# frozen_string_literal: true

module Protostar
  module Schema
    # A registry of built files, safe to use from several threads. The pool
    # itself is mutable and not shareable between Ractors; the files it holds are.
    class Pool
      #: () -> void
      def initialize
        @mutex = Mutex.new
        @files = {}
        @symbols = {}
        @packages = {}
        @extensions = {}
      end

      # Registers a built file and everything it defines.
      #
      # An extension whose extendee and number another file already uses is
      # accepted with a warning, as protoc does; #find_extension keeps
      # returning the first one.
      #
      # - `warn`: write that warning with `Kernel#warn`; the
      #   compiler passes false and reports it as a diagnostic instead
      #
      # Raises Error when the file name is taken, a symbol or package it
      # defines clashes with one already in the pool, or the file itself uses
      # an extension number twice.
      #: (File file, ?warn: bool) -> File
      def add(file, warn: true)
        raise Error, "expected a #{File.name}, got #{file.class}" unless file.is_a?(File)
        raise Error, "#{file.name} is not frozen; finish its draft with freeze!" unless file.frozen?
        taken = @mutex.synchronize do
          check_clashes(file)
          @files[file.name] = file
          file.symbols.each { |name, symbol| @symbols[name] = symbol }
          package_prefixes(file.package).each { |pkg| @packages[pkg] ||= file }
          file.all_extensions.filter_map do |ext|
            by_number = (@extensions[ext.extendee.full_name] ||= {})
            existing = by_number[ext.number]
            by_number[ext.number] = ext unless existing
            [ext, existing] if existing
          end
        end
        if warn
          taken.each do |ext, existing|
            Kernel.warn("#{file.name}: Extension number #{ext.number} has already been used in " \
              "\"#{ext.extendee.full_name}\" by extension \"#{existing.full_name}\" defined in #{existing.file.name}.")
          end
        end
        file
      end

      #: (String name) -> File?
      def file(name)
        @mutex.synchronize { @files[name] }
      end

      # Returns whether a file of that name is registered.
      #: (untyped file_name) -> bool
      def include?(file_name)
        @mutex.synchronize { @files.key?(file_name) }
      end

      # Returns them in the order they were added.
      #: () -> Array[File]
      def files
        @mutex.synchronize { @files.values }
      end

      # - `full_name`: without a leading dot
      #
      # Returns any symbol: message, field, oneof, enum, enum value, service or method.
      #: (String full_name) -> Descriptor?
      def find_symbol(full_name)
        @mutex.synchronize { @symbols[full_name] }
      end

      #: (String full_name) -> Message?
      def find_message(full_name)
        found = find_symbol(full_name)
        found if found.is_a?(Message)
      end

      #: (String full_name) -> Enum?
      def find_enum(full_name)
        found = find_symbol(full_name)
        found if found.is_a?(Enum)
      end

      #: (untyped full_name) -> Service?
      def find_service(full_name)
        found = find_symbol(full_name)
        found if found.is_a?(Service)
      end

      # - `extendee`: the extended message or its full name
      #: ((String | Message) extendee, Integer number) -> Field?
      def find_extension(extendee, number)
        extendee = extendee.full_name if extendee.is_a?(Message)
        @mutex.synchronize { @extensions[extendee]&.[](number) }
      end

      # Returns every registered extension of the message, by number.
      #: ((String | Message) extendee) -> Array[Field]
      def extensions_of(extendee)
        extendee = extendee.full_name if extendee.is_a?(Message)
        @mutex.synchronize { (@extensions[extendee] || {}).values.sort_by(&:number) }
      end

      def inspect
        "#<#{self.class.name} #{@files.size} files>"
      end

      # Builds and adds a serialized FileDescriptorProto, unless a file of that name is here
      #: (untyped bytes) -> File
      def add_serialized_file(bytes)
        proto = Proto.types::FileDescriptorProto.decode(bytes)
        file(proto.name) || add(File.from_proto(proto, pool: self))
      end

      # See Protostar.load_descriptor_set.
      def load_descriptor_set(bytes)
        Protostar.load_descriptor_set(bytes, pool: self)
      end

      private

      def check_clashes(file)
        raise Error, "file \"#{file.name}\" is already in the pool" if @files.key?(file.name)
        file.symbols.each do |name, symbol|
          if (other = @symbols[name])
            raise Error, "\"#{name}\" is already defined in file \"#{other.file.name}\" (redefined in \"#{file.name}\")"
          end
          if (pkg_file = @packages[name])
            raise Error, "\"#{name}\" is already defined as a package in file \"#{pkg_file.name}\" " \
              "(redefined as a #{symbol.class.name.split("::").last} in \"#{file.name}\")"
          end
        end
        package_prefixes(file.package).each do |pkg|
          other = @symbols[pkg] || file.symbols[pkg]
          next unless other
          raise Error, "\"#{pkg}\" is already defined (as something other than a package) in file \"#{other.file.name}\""
        end
        seen = {}
        file.all_extensions.each do |ext|
          key = [ext.extendee.full_name, ext.number]
          if (existing = seen[key])
            raise Error, "extension number #{ext.number} of \"#{ext.extendee.full_name}\" is already used by " \
              "\"#{existing.full_name}\" (redefined by \"#{ext.full_name}\")"
          end
          seen[key] = ext
        end
      end

      def package_prefixes(package)
        return [] if package.empty?
        parts = package.split(".")
        (1..parts.size).map { |n| parts.first(n).join(".") }
      end
    end
  end
end

module Protostar
  @generated_pool = Schema::Pool.new

  class << self
    # The process-wide pool generated `_pb.rb` files build into.
    attr_reader :generated_pool #: Schema::Pool

    # Builds every file of a serialized `FileDescriptorSet` into a pool, in
    # order. Custom options are decoded against the extensions the pool (and
    # the file itself) defines; files already in the pool are taken from it.
    #
    # - `bytes`: a serialized google.protobuf.FileDescriptorSet
    #: (String bytes, pool: Schema::Pool) -> Array[Schema::File]
    def load_descriptor_set(bytes, pool:)
      Schema::Proto.each_file(bytes).map { |file_bytes| pool.add_serialized_file(file_bytes) }
    end
  end

  Pool = Schema::Pool
end
