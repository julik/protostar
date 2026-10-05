# frozen_string_literal: true

module Protostar
  class Compiler
    # The names visible while one file is linked: its own symbols, read from
    # the AST as they are defined, and everything in the pool. Lookups follow
    # protoc's DescriptorBuilder (FindSymbol and LookupSymbolNoPlaceholder):
    # the same first-component scoping rule as {Schema::Resolver}, with a
    # symbol in another file visible only through a direct import or a chain
    # of `import public`, and with the failure explanations protoc gives.
    #
    # @api private
    class SymbolTable
      # A named thing: `kind` is :message, :enum, :enum_value, :field,
      # :oneof, :service, :method or :package; `object` is the AST node for
      # the file being linked and the Schema descriptor otherwise
      Symbol = ::Struct.new(:kind, :full_name, :file_name, :object) do
        def type?
          kind == :message || kind == :enum
        end

        def aggregate?
          kind == :message || kind == :package || kind == :enum || kind == :service
        end

        def local?
          object.is_a?(AST::Node)
        end
      end

      SCHEMA_KINDS = {
        Schema::Message => :message, Schema::Enum => :enum, Schema::EnumValue => :enum_value,
        Schema::Field => :field, Schema::Oneof => :oneof, Schema::Service => :service, Schema::Method => :method
      }.freeze

      # @return [String, nil] set when the last failed lookup found the name in a file that is not imported
      attr_reader :undeclared_file, :undeclared_name
      # @return [String, nil] set when the last failed lookup resolved a compound name to a missing symbol
      attr_reader :unresolved_name
      # @return [Array<String>] direct imports no lookup has used yet
      attr_reader :unused

      # @param file_name [String] the file being linked
      # @param package [String]
      # @param pool [Schema::Pool]
      # @param dependencies [Array<Schema::File, nil>] direct imports, nil where missing
      # @param option_dependencies [Array<Schema::File, nil>] `import option` files
      # @param unused [Array<Schema::File>] imports to report when never used
      def initialize(file_name, package, pool, dependencies, option_dependencies, unused)
        @file_name = file_name
        @package = package
        @pool = pool
        @local = {}
        @visible = {}
        dependencies.each { |dep| record_public(dep, @visible) }
        @option_visible = {}
        option_dependencies.each { |dep| record_public(dep, @option_visible) }
        @unused = unused.map(&:name)
        @packages = {}
        pool.files.each { |f| add_package_names(f.package, f.name) }
        @local_packages = []
      end

      # @return [Hash{String => Symbol}] the file's own symbols
      attr_reader :local

      # Registers a symbol of the file being linked
      # @return [Symbol, nil] the existing symbol when the name is taken
      def add(kind, full_name, node)
        existing = find_any(full_name)
        return existing if existing
        @local[full_name] = Symbol.new(kind, full_name, @file_name, node)
        nil
      end

      # Registers the file's package and its parents, as AddPackage does
      # @return [Symbol, nil] a non-package symbol already using one of the names
      def add_package(package)
        existing = find_any(package)
        if existing.nil?
          @packages[package] ||= @file_name
          @local_packages << package
          cut = package.rindex(".")
          return add_package(package[0, cut]) if cut
        elsif existing.kind != :package
          return existing
        end
        nil
      end

      # Any symbol by full name, ignoring visibility
      # @return [Symbol, nil]
      def find_any(full_name)
        if (sym = @local[full_name])
          return sym
        end
        if (descriptor = @pool.find_symbol(full_name))
          return Symbol.new(SCHEMA_KINDS.fetch(descriptor.class), full_name, descriptor.file.name, descriptor)
        end
        if (owner = @packages[full_name])
          return Symbol.new(:package, full_name, owner, nil)
        end
        nil
      end

      # FindSymbolNotEnforcingDeps: any symbol, marking its file's import as used
      def find_not_enforcing_deps(full_name)
        sym = find_any(full_name)
        if sym && sym.kind != :package && (@visible.key?(sym.file_name) || @option_visible.key?(sym.file_name))
          @unused.delete(sym.file_name)
        end
        sym
      end

      # FindSymbol: a symbol visible from the file being linked, or nil (and
      # {#undeclared_file} set) when it lives in a file that is not imported
      def find(full_name)
        sym = find_not_enforcing_deps(full_name)
        return nil if sym.nil?
        return sym if sym.file_name == @file_name || @visible.key?(sym.file_name)
        return sym if @option_visible.key?(sym.file_name) && sym.kind == :field
        if sym.kind == :package
          return sym if in_package?(@package, full_name)
          return sym if @visible.each_value.any? { |f| in_package?(f.package, full_name) }
          return sym if @option_visible.each_value.any? { |f| in_package?(f.package, full_name) }
        end
        @undeclared_file = sym.file_name
        @undeclared_name = full_name
        nil
      end

      # LookupSymbolNoPlaceholder
      # @param name [String] as written, maybe with a leading dot
      # @param relative_to [String] full name of the element doing the lookup
      # @param types_only [Boolean] skip simple names that are not types
      # @return [Symbol, nil]
      def lookup(name, relative_to, types_only: false)
        @undeclared_file = nil
        @undeclared_name = nil
        @unresolved_name = nil
        return find(name[1..]) if name.start_with?(".")

        dot = name.index(".")
        first = dot ? name[0, dot] : name
        scope = relative_to.dup
        loop do
          cut = scope.rindex(".")
          return find(name) if cut.nil?
          scope = scope[0, cut]
          candidate = "#{scope}.#{first}"
          sym = find(candidate)
          next if sym.nil?
          if dot
            next unless sym.aggregate?
            full = "#{scope}.#{name}"
            found = find(full)
            @unresolved_name = full if found.nil?
            return found
          end
          return sym unless types_only && !sym.type?
        end
      end

      # AddNotDefinedError's messages for the last failed {#lookup}
      # @return [Array<String>]
      def not_defined_messages(name)
        if @undeclared_file.nil? && @unresolved_name.nil?
          return ["\"#{name}\" is not defined."]
        end
        messages = []
        if @undeclared_file
          messages << "\"#{@undeclared_name}\" seems to be defined in \"#{@undeclared_file}\", which is not " \
            "imported by \"#{@file_name}\".  To use it here, please add the necessary import."
        end
        if @unresolved_name
          messages << "\"#{name}\" is resolved to \"#{@unresolved_name}\", which is not defined. The innermost " \
            "scope is searched first in name resolution. Consider using a leading '.'(i.e., \".#{name}\") to start " \
            "from the outermost scope."
        end
        messages
      end

      private

      def record_public(file, into)
        return if file.nil? || into.key?(file.name)
        into[file.name] = file
        file.public_dependencies.each { |i| record_public(file.dependency_files[i], into) }
      end

      def add_package_names(package, file_name)
        return if package.empty?
        parts = package.split(".")
        parts.size.downto(1) { |n| @packages[parts.first(n).join(".")] ||= file_name }
      end

      def in_package?(package, name)
        package == name || (package.start_with?(name) && package.getbyte(name.bytesize) == 46) # "."
      end
    end
  end
end
