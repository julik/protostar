# frozen_string_literal: true

module Protostar
  module Schema
    # A registry of built files, safe to use from several threads. The pool
    # itself is mutable and not shareable between Ractors; the files it holds are.
    class Pool
      def initialize
        @mutex = Mutex.new
        @files = {}
        @symbols = {}
        @packages = {}
        @extensions = {}
      end

      # Registers a built file and everything it defines
      # @param file [File]
      # @return [File]
      # @raise [Error] when the file name is taken, or a symbol, package or
      #   extension number it defines clashes with one already in the pool
      def add(file)
        raise Error, "expected a #{File.name}, got #{file.class}" unless file.is_a?(File)
        raise Error, "#{file.name} is not frozen; build it with Builder" unless file.frozen?
        @mutex.synchronize do
          check_clashes(file)
          @files[file.name] = file
          file.symbols.each { |name, symbol| @symbols[name] = symbol }
          package_prefixes(file.package).each { |pkg| @packages[pkg] ||= file }
          file.all_extensions.each do |ext|
            (@extensions[ext.extendee.full_name] ||= {})[ext.number] = ext
          end
        end
        file
      end

      # @return [File, nil]
      def file(name)
        @mutex.synchronize { @files[name] }
      end

      # @return [Boolean] whether a file of that name is registered
      def include?(file_name)
        @mutex.synchronize { @files.key?(file_name) }
      end

      # @return [Array<File>] in the order they were added
      def files
        @mutex.synchronize { @files.values }
      end

      # @param full_name [String] without a leading dot
      # @return [Descriptor, nil] any symbol: message, field, oneof, enum, enum value, service or method
      def find_symbol(full_name)
        @mutex.synchronize { @symbols[full_name] }
      end

      # @return [Message, nil]
      def find_message(full_name)
        found = find_symbol(full_name)
        found if found.is_a?(Message)
      end

      # @return [Enum, nil]
      def find_enum(full_name)
        found = find_symbol(full_name)
        found if found.is_a?(Enum)
      end

      # @return [Service, nil]
      def find_service(full_name)
        found = find_symbol(full_name)
        found if found.is_a?(Service)
      end

      # @param extendee [String, Message] the extended message or its full name
      # @param number [Integer]
      # @return [Field, nil]
      def find_extension(extendee, number)
        extendee = extendee.full_name if extendee.is_a?(Message)
        @mutex.synchronize { @extensions[extendee]&.[](number) }
      end

      # @param extendee [String, Message]
      # @return [Array<Field>] every registered extension of the message, by number
      def extensions_of(extendee)
        extendee = extendee.full_name if extendee.is_a?(Message)
        @mutex.synchronize { (@extensions[extendee] || {}).values.sort_by(&:number) }
      end

      def inspect
        "#<#{self.class.name} #{@files.size} files>"
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
        file.all_extensions.each do |ext|
          existing = @extensions[ext.extendee.full_name]&.[](ext.number)
          next unless existing
          raise Error, "extension number #{ext.number} of \"#{ext.extendee.full_name}\" is already used by " \
            "\"#{existing.full_name}\" (redefined by \"#{ext.full_name}\")"
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
