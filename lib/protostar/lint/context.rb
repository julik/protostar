# frozen_string_literal: true

module Protostar
  module Lint
    # What a rule sees of one compiled file: the frozen Schema::File, the
    # AST with its recorded positions, the source locations with their
    # comments, the text, and the compiler's warnings for it.
    class Context
      # Source paths of `FileDescriptorProto` fields the rules point at
      PATHS = {syntax: [12], edition: [14], package: [2]}.freeze

      # The file name as imported.
      attr_reader :name #: String
      # The file on disk, as diagnostics print it.
      attr_reader :path #: String?
      # The file on disk, absolute.
      attr_reader :disk_path #: String?
      attr_reader :file #: untyped
      attr_reader :ast #: untyped
      # The file's bytes.
      attr_reader :text #: String
      # The compiler's warnings for the file.
      attr_reader :warnings #: Array[Compiler::Diagnostic]
      # Every file of the lint run, this one included.
      attr_reader :all #: Array[Context]

      # - `linker`: the linker that built the file
      #: (name: untyped, path: untyped, disk_path: untyped, linker: Compiler::Linker, text: untyped, warnings: untyped, all: untyped) -> void
      def initialize(name:, path:, disk_path:, linker:, text:, warnings:, all:)
        @name = name
        @path = path
        @disk_path = disk_path
        @linker = linker
        @file = linker.file
        @ast = linker.ast
        @text = text
        @warnings = warnings
        @all = all
        @extents = {}
        @ast.locations.each do |loc|
          span = loc.span
          next if span.size < 3
          finish = (span.size == 4) ? [span[2], span[3]] : [span[0], span[2]]
          key = [span[0], span[1]]
          @extents[key] = finish if @extents[key].nil? || (finish <=> @extents[key]) < 0
        end
        @by_path = {}
        @linker.locations.each { |loc| @by_path[loc.path] ||= loc }
      end

      #: () -> Diagnostics::Source
      def source
        @source ||= Diagnostics::Source.new(@text)
      end

      # Every element of a kind, as protoc visits them, without the map entry
      # messages and synthetic oneofs the compiler made up
      #
      # - `kind`: :message, :field, :oneof, :enum, :enum_value, :service or :method
      #: (Symbol kind) { (untyped node, untyped descriptor) -> void } -> void
      def each(kind)
        @linker.each_element do |node, k|
          next unless k == kind
          descriptor = @linker.descriptor_of(node)
          next if synthetic?(node, kind, descriptor)
          yield node, descriptor
        end
      end

      # Returns what the compiler built for a node.
      #: (untyped node) -> untyped
      def descriptor(node)
        @linker.descriptor_of(node)
      end

      # - `kind`: a position kind the parser recorded: :name, :number, :type, ...
      #
      # Returns from the position to the end of the element that starts there.
      #: (untyped node, Symbol kind, ?label: String?, ?primary: bool) -> Diagnostics::Span?
      def span(node, kind, label: nil, primary: true)
        line, column = node.position(kind)
        # oneofs record no position; every element's name is field 1 of its descriptor
        return span_at(node.path + [1], label: label, primary: primary) if line.nil? && kind == :name && node.path
        return nil unless line
        end_line, end_column = @extents[[line, column]]
        Diagnostics::Span.new(line + 1, column + 1, end_line && end_line + 1, end_column && end_column + 1,
          label: label, primary: primary)
      end

      # - `path`: a source path, e.g. [3, 0] for the first import
      #
      # Returns the span of the first location with that path.
      #: (Array[Integer] path, ?label: String?, ?primary: bool) -> Diagnostics::Span?
      def span_at(path, label: nil, primary: true)
        loc = @by_path[path]
        return nil unless loc
        s = loc.span
        end_line = (s.size == 4) ? s[2] : s[0]
        Diagnostics::Span.new(s[0] + 1, s[1] + 1, end_line + 1, s.last + 1, label: label, primary: primary)
      end

      # Returns the leading comment of an element, or its trailing
      # one, stripped; nil when it has none.
      #: (untyped node) -> String?
      def comment(node)
        loc = node.path && @by_path[node.path]
        return nil unless loc
        [loc.leading_comments, loc.trailing_comments].compact.map(&:strip).find { |c| !c.empty? }
      end

      # Whether renaming `from` to `to` is safe to do mechanically: `from` is
      # written once in the file, as the declaration, and `to` nowhere
      #: (String from, String to) -> bool
      def renamable?(from, to)
        @words ||= @text.b.scan(/[A-Za-z_][A-Za-z0-9_]*/).tally
        @words[from.b] == 1 && !@words.key?(to.b)
      end

      private

      def synthetic?(node, kind, descriptor)
        case kind
        when :message then descriptor.map_entry?
        when :oneof then descriptor.synthetic?
        when :field then descriptor.containing_message&.map_entry? || false
        else false
        end
      end
    end
  end
end
