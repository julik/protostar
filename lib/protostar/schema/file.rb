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

      def inspect
        "#<#{self.class.name} #{@name}>"
      end
      alias_method :to_s, :inspect

      # This file as a `google.protobuf.FileDescriptorProto` of the bootstrap
      # classes, as protoc's `FileDescriptor::CopyTo` writes it
      # @param source_info [Boolean] include `source_code_info` when the file has it
      # @param default_json_names [Boolean] false leaves out every `json_name` equal to the one
      #   derived from the field name, as protoc's Ruby generator embeds descriptors
      # @return [Protostar::Google::Protobuf::FileDescriptorProto]
      def to_proto(source_info: true, default_json_names: true)
        Proto::Writer.file(self, source_info: source_info, json_names: default_json_names)
      end

      # @param (see #to_proto)
      # @return [String] the serialized FileDescriptorProto, byte for byte what protoc writes
      def serialize(source_info: true, default_json_names: true)
        bytes = to_proto(source_info: false, default_json_names: default_json_names).encode
        return bytes unless source_info && @source_info
        Proto::Writer.with_source_code_info(bytes, @source_info)
      end

      # Builds a file from a `google.protobuf.FileDescriptorProto` message (or
      # its bytes), as a plugin receives them. Extension bytes in options are
      # decoded by the extensions the pool (or the file itself) defines;
      # others stay {Options#unknown_fields}.
      # @param proto [Protostar::Google::Protobuf::FileDescriptorProto, String]
      # @param pool [Pool] where dependencies and extensions are looked up; the file is not added
      # @return [File]
      def self.from_proto(proto, pool:)
        proto = Proto.types::FileDescriptorProto.decode(proto) if proto.is_a?(String)
        Proto::Reader.new(proto, pool).call
      end

      # Starts describing a file. The draft creates the real descriptors as it
      # goes; {Draft::File#resolve} links them and {Draft::File#freeze!} hands
      # back the finished, shareable file.
      #
      #   file = Schema::File.draft("shop.proto", package: "shop", syntax: :proto3)
      #   file.message("Item") do |m|
      #     m.field "name", 1, :string
      #     m.field "price_cents", 2, :int64, optional: true
      #     m.map "stock", 3, key: :string, value: :int32
      #   end
      #   file.resolve(pool)
      #   file.freeze!  # => #<Protostar::Schema::File shop.proto>
      #
      # @param name [String] the file name as imported
      # @param package [String, nil]
      # @param syntax [Symbol, nil] :proto2, :proto3 or :editions; nil is proto2, and
      #   unlike an explicit :proto2 leaves `syntax` out of the FileDescriptorProto, as protoc does
      # @param edition [Symbol, Integer, nil] e.g. :EDITION_2023; implies :editions
      # @param dependencies [Array<String>] imported file names
      # @param public_dependencies [Array<String, Integer>] names or indexes of `import public` files
      # @param weak_dependencies [Array<String, Integer>]
      # @param option_dependencies [Array<String>] `import option` file names
      # @param options [Hash, nil] the file's options
      # @return [Draft::File]
      def self.draft(name, package: nil, syntax: nil, edition: nil, dependencies: [], public_dependencies: [],
        weak_dependencies: [], option_dependencies: [], options: nil)
        Draft::File.new(name, package: package, syntax: syntax, edition: edition, dependencies: dependencies,
          public_dependencies: public_dependencies, weak_dependencies: weak_dependencies,
          option_dependencies: option_dependencies, options: options)
      end

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
