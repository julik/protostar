# frozen_string_literal: true

module Protostar
  module Schema
    # A built `.proto` file
    class File < Descriptor
      # @return [String] the package, "" when none
      attr_reader :package
      # @return [Symbol] :proto2, :proto3 or :editions
      attr_reader :syntax
      # @return [Symbol, Integer, nil] the Edition enum name for editions files
      #   (an Integer only for an edition this model has no name for)
      attr_reader :edition
      # @return [Array<String>] imported file names, in declaration order
      attr_reader :dependencies
      # @return [Array<Integer>] indexes into {#dependencies} of `import public`
      attr_reader :public_dependencies
      # @return [Array<Integer>] indexes into {#dependencies} of `import weak`
      attr_reader :weak_dependencies
      # @return [Array<String>] `import option` file names (edition 2024)
      attr_reader :option_dependencies
      # @return [Array<File>] linked {#dependencies}, same order
      attr_reader :dependency_files
      # @return [Array<Message>] top-level messages
      attr_reader :messages
      # @return [Array<Enum>] top-level enums
      attr_reader :enums
      # @return [Array<Service>]
      attr_reader :services
      # @return [Array<Field>] top-level extensions
      attr_reader :extensions
      # @return [SourceInfo, nil]
      attr_reader :source_info
      # @return [Array<Message>] every message, depth first in declaration order
      attr_reader :all_messages
      # @return [Array<Enum>] every enum, top level first, then by message in {#all_messages} order
      attr_reader :all_enums
      # @return [Array<Field>] every extension, top level first, then by message in {#all_messages} order
      attr_reader :all_extensions
      # @return [Hash{String => Descriptor}] every symbol this file defines, by full name
      attr_reader :symbols
      # @return [Array<File>] this file, its imports and whatever they re-export
      #   through `import public`: the files whose symbols are visible here
      attr_reader :visible_files

      # @api private
      def initialize(name:, package:, syntax:, edition:, proto_syntax:)
        @name = name
        @full_name = name
        @index = 0
        @package = package
        @syntax = syntax
        @edition = edition
        @proto_syntax = proto_syntax
        @dependencies = Freezer::EMPTY_ARRAY
        @public_dependencies = Freezer::EMPTY_ARRAY
        @weak_dependencies = Freezer::EMPTY_ARRAY
        @option_dependencies = Freezer::EMPTY_ARRAY
        @dependency_files = Freezer::EMPTY_ARRAY
        @messages = @enums = @services = @extensions = Freezer::EMPTY_ARRAY
        @all_messages = @all_enums = @all_extensions = Freezer::EMPTY_ARRAY
        @symbols = {}
        @visible_files = [self]
      end

      # @api private
      def __dependencies(dependencies:, public_dependencies:, weak_dependencies:, option_dependencies:, dependency_files:)
        @dependencies = dependencies
        @public_dependencies = public_dependencies
        @weak_dependencies = weak_dependencies
        @option_dependencies = option_dependencies
        @dependency_files = dependency_files
        @visible_files = compute_visible_files
        self
      end

      # @api private
      # @return [String, nil] the `syntax` string the FileDescriptorProto carries
      attr_reader :proto_syntax

      # @return [File] itself, so every descriptor answers `#file`
      def file
        self
      end

      # @return [Integer] the edition number features resolve against
      #   (EDITION_PROTO2 or EDITION_PROTO3 for the legacy syntaxes)
      def edition_number
        case @syntax
        when :proto2 then Features::EDITIONS[:EDITION_PROTO2]
        when :proto3 then Features::EDITIONS[:EDITION_PROTO3]
        else Features.edition_number(@edition)
        end
      end

      # @param full_name [String] without a leading dot
      # @return [Message, nil] a message defined in this file
      def find_message(full_name)
        found = @symbols[full_name]
        found if found.is_a?(Message)
      end

      # @return [Enum, nil] an enum defined in this file
      def find_enum(full_name)
        found = @symbols[full_name]
        found if found.is_a?(Enum)
      end

      # @return [Service, nil] a service defined in this file
      def find_service(full_name)
        found = @symbols[full_name]
        found if found.is_a?(Service)
      end

      # @return [Field, nil] an extension defined in this file
      def find_extension(full_name)
        found = @symbols[full_name]
        found if found.is_a?(Field) && found.extension?
      end

      # @return [Descriptor, nil] any symbol defined in this file: message, field,
      #   oneof, enum, enum value, service or method
      def find_symbol(full_name)
        @symbols[full_name]
      end

      # @return [Hash] the FileDescriptorProto hash
      def to_h
        h = {name: @name}
        h[:package] = @package unless @package.empty?
        h[:dependency] = @dependencies unless @dependencies.empty?
        h[:public_dependency] = @public_dependencies unless @public_dependencies.empty?
        h[:weak_dependency] = @weak_dependencies unless @weak_dependencies.empty?
        h[:option_dependency] = @option_dependencies unless @option_dependencies.empty?
        h[:message_type] = @messages.map(&:to_h) unless @messages.empty?
        h[:enum_type] = @enums.map(&:to_h) unless @enums.empty?
        h[:service] = @services.map(&:to_h) unless @services.empty?
        h[:extension] = @extensions.map(&:to_h) unless @extensions.empty?
        options_to_h(h)
        h[:source_code_info] = @source_info.to_h if @source_info
        h[:syntax] = @proto_syntax if @proto_syntax
        h[:edition] = @edition if @edition
        h
      end

      def inspect
        "#<#{self.class.name} #{@name}>"
      end
      alias_method :to_s, :inspect

      private

      # protoc's rule: direct imports, plus the public imports of those, recursively
      def compute_visible_files
        seen = {self => true}
        queue = []
        @dependency_files.each do |dep|
          next if seen[dep]
          seen[dep] = true
          queue << dep
        end
        until queue.empty?
          dep = queue.shift
          dep.public_dependencies.each do |i|
            pub = dep.dependency_files[i]
            next if pub.nil? || seen[pub]
            seen[pub] = true
            queue << pub
          end
        end
        seen.keys
      end
    end
  end
end
