# frozen_string_literal: true

module Protostar
  module Schema
    # protoc's C++-style scoped name lookup (`DescriptorBuilder::LookupSymbol`),
    # as `FieldDescriptorProto.type_name` in descriptor.proto describes it.
    #
    # A name with a leading dot is fully qualified. Otherwise the *first component*
    # is looked up in the innermost scope, then each enclosing scope out to the
    # root; once it is found (as something that can contain names), the rest of
    # the name must resolve beneath it or the lookup fails without searching
    # further out. Only symbols of the file itself, its direct imports and
    # whatever those re-export through `import public` are visible.
    module Resolver
      # Stands for "this name is a package" during lookup
      PACKAGE = Object.new.freeze

      # - `name`: the name as written, e.g. "Foo.Bar" or ".pkg.Foo.Bar"
      # - `scope`: full name of the enclosing message, or the package ("" for none)
      # - `file`: the file doing the lookup; it may still be under construction
      # - `pool`: consulted only to explain a failure ("not imported")
      # - `types_only`: when a simple (one-component) name finds something
      #   that is not a message or enum, keep searching outward, as protoc does for
      #   type names. Compound names return whatever they reach.
      #
      # Raises ResolveError.
      #: (String name, scope: String, file: File, ?pool: Pool?, ?types_only: bool) -> Descriptor
      def self.resolve(name, scope:, file:, pool: nil, types_only: true)
        if !name.is_a?(String) || name.empty? || name == "."
          raise ResolveError.new("#{name.inspect} is not a valid name", name: name, scope: scope)
        end

        if name.start_with?(".")
          found = find(name[1..], file)
          return found if found && !found.equal?(PACKAGE)
          raise not_defined(name, scope, file, pool)
        end

        dot = name.index(".")
        first = dot ? name[0, dot] : name
        prefix = scope
        loop do
          candidate = prefix.empty? ? first : "#{prefix}.#{first}"
          found = find(candidate, file)
          if found
            if dot
              if aggregate?(found)
                full = prefix.empty? ? name : "#{prefix}.#{name}"
                inner = find(full, file)
                return inner if inner && !inner.equal?(PACKAGE)
                raise ResolveError.new(
                  "\"#{name}\" is resolved to \"#{full}\", which is not defined. The innermost scope is " \
                  "searched first in name resolution. Consider using a leading '.'(i.e., \".#{name}\") " \
                  "to start from the outermost scope (scope \"#{scope}\" in #{file.name})",
                  name: name, scope: scope
                )
              end
            elsif !found.equal?(PACKAGE) && (!types_only || type?(found))
              return found
            end
          end
          break if prefix.empty?
          cut = prefix.rindex(".")
          prefix = cut ? prefix[0, cut] : ""
        end
        raise not_defined(name, scope, file, pool)
      end

      # A visible symbol by full name, PACKAGE for a visible package, or nil
      def self.find(full_name, file) # :nodoc:
        visible = file.visible_files
        visible.each do |f|
          found = f.symbols[full_name]
          return found if found
        end
        visible.each do |f|
          return PACKAGE if in_package?(f.package, full_name)
        end
        nil
      end

      def self.in_package?(package, name) # :nodoc:
        package == name || (package.start_with?(name) && package.getbyte(name.bytesize) == 46) # "."
      end

      def self.type?(found) # :nodoc:
        found.is_a?(Message) || found.is_a?(Enum)
      end

      def self.aggregate?(found) # :nodoc:
        found.equal?(PACKAGE) || found.is_a?(Message) || found.is_a?(Enum) || found.is_a?(Service)
      end

      def self.not_defined(name, scope, file, pool)
        message = "\"#{name}\" is not defined (scope \"#{scope}\" in #{file.name})"
        if pool
          elsewhere = candidates(name, scope).lazy.map { |c| pool.find_symbol(c) }.find(&:itself)
          if elsewhere
            message = "\"#{elsewhere.full_name}\" seems to be defined in \"#{elsewhere.file.name}\", which is " \
              "not imported by \"#{file.name}\".  To use it here, please add the necessary import."
          end
        end
        ResolveError.new(message, name: name, scope: scope)
      end
      private_class_method :not_defined

      def self.candidates(name, scope)
        return [name[1..]] if name.start_with?(".")
        parts = scope.empty? ? [] : scope.split(".")
        parts.size.downto(0).map { |i| (parts.first(i) + [name]).join(".") }
      end
      private_class_method :candidates
    end
  end
end
