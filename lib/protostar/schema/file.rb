# frozen_string_literal: true

module Protostar
  module Schema
    # A built `.proto` file
    class File < Descriptor
      # The package, "" when none.
      attr_reader :package #: String
      # :proto2, :proto3 or :editions.
      attr_reader :syntax #: Symbol
      # The Edition enum name for editions files
      # (an Integer only for an edition this model has no name for).
      attr_reader :edition #: (Symbol | Integer)?
      # Imported file names, in declaration order.
      attr_reader :dependencies #: Array[String]
      # Indexes into #dependencies of `import public`.
      attr_reader :public_dependencies #: Array[Integer]
      # Indexes into #dependencies of `import weak`.
      attr_reader :weak_dependencies #: Array[Integer]
      # `import option` file names (edition 2024).
      attr_reader :option_dependencies #: Array[String]
      # Linked #dependencies, same order.
      attr_reader :dependency_files #: Array[File]
      # Top-level messages.
      attr_reader :messages #: Array[Message]
      # Top-level enums.
      attr_reader :enums #: Array[Enum]
      attr_reader :services #: Array[Service]
      # Top-level extensions.
      attr_reader :extensions #: Array[Field]
      attr_reader :source_info #: SourceInfo?
      # Every message, depth first in declaration order.
      attr_reader :all_messages #: Array[Message]
      # Every enum, top level first, then by message in #all_messages order.
      attr_reader :all_enums #: Array[Enum]
      # Every extension, top level first, then by message in #all_messages order.
      attr_reader :all_extensions #: Array[Field]
      # Every symbol this file defines, by full name.
      attr_reader :symbols #: Hash[String, Descriptor]
      # This file, its imports and whatever they re-export
      # through `import public`: the files whose symbols are visible here.
      attr_reader :visible_files #: Array[File]

      def initialize(name:, package:, syntax:, edition:, proto_syntax:) # :nodoc:
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

      def __dependencies(dependencies:, public_dependencies:, weak_dependencies:, option_dependencies:, dependency_files:) # :nodoc:
        @dependencies = dependencies
        @public_dependencies = public_dependencies
        @weak_dependencies = weak_dependencies
        @option_dependencies = option_dependencies
        @dependency_files = dependency_files
        @visible_files = compute_visible_files
        self
      end

      # :stopdoc:
      # The `syntax` string the FileDescriptorProto carries.
      attr_reader :proto_syntax #: String?
      # :startdoc:

      # Returns itself, so every descriptor answers `#file`.
      #: () -> File
      def file
        self
      end

      # Returns the edition number features resolve against
      # (EDITION_PROTO2 or EDITION_PROTO3 for the legacy syntaxes).
      #: () -> Integer
      def edition_number
        case @syntax
        when :proto2 then Features::EDITIONS[:EDITION_PROTO2]
        when :proto3 then Features::EDITIONS[:EDITION_PROTO3]
        else Features.edition_number(@edition)
        end
      end

      # - `full_name`: without a leading dot
      #
      # Returns a message defined in this file.
      #: (String full_name) -> Message?
      def find_message(full_name)
        found = @symbols[full_name]
        found if found.is_a?(Message)
      end

      # Returns an enum defined in this file.
      #: (String full_name) -> Enum?
      def find_enum(full_name)
        found = @symbols[full_name]
        found if found.is_a?(Enum)
      end

      # Returns a service defined in this file.
      #: (untyped full_name) -> Service?
      def find_service(full_name)
        found = @symbols[full_name]
        found if found.is_a?(Service)
      end

      # Returns an extension defined in this file.
      #: (untyped full_name) -> Field?
      def find_extension(full_name)
        found = @symbols[full_name]
        found if found.is_a?(Field) && found.extension?
      end

      # Returns any symbol defined in this file: message, field,
      # oneof, enum, enum value, service or method.
      #: (untyped full_name) -> Descriptor?
      def find_symbol(full_name)
        @symbols[full_name]
      end

      def inspect
        "#<#{self.class.name} #{@name}>"
      end
      alias_method :to_s, :inspect

      # This file as a `google.protobuf.FileDescriptorProto` of the bootstrap
      # classes, as protoc's `FileDescriptor::CopyTo` writes it
      #
      # - `source_info`: include `source_code_info` when the file has it
      # - `default_json_names`: false leaves out every `json_name` equal to the one
      #   derived from the field name, as protoc's Ruby generator embeds descriptors
      #: (?source_info: bool, ?default_json_names: bool) -> Protostar::Google::Protobuf::FileDescriptorProto
      def to_proto(source_info: true, default_json_names: true)
        Proto::Writer.file(self, source_info: source_info, json_names: default_json_names)
      end

      # - `(see`: #to_proto)
      #
      # Returns the serialized FileDescriptorProto, byte for byte what protoc writes.
      #: (?source_info: bool, ?default_json_names: bool) -> String
      def serialize(source_info: true, default_json_names: true)
        bytes = to_proto(source_info: false, default_json_names: default_json_names).encode
        return bytes unless source_info && @source_info
        Proto::Writer.with_source_code_info(bytes, @source_info)
      end

      # Builds a file from a `google.protobuf.FileDescriptorProto` message (or
      # its bytes), as a plugin receives them. Extension bytes in options are
      # decoded by the extensions the pool (or the file itself) defines;
      # others stay Options#unknown_fields.
      #
      # - `pool`: where dependencies and extensions are looked up; the file is not added
      #: ((Protostar::Google::Protobuf::FileDescriptorProto | String) proto, pool: Pool) -> File
      def self.from_proto(proto, pool:)
        proto = Proto.types::FileDescriptorProto.decode(proto) if proto.is_a?(String)
        Proto::Reader.new(proto, pool).call
      end

      # Starts describing a file. The draft creates the real descriptors as it
      # goes; Draft::File#resolve links them and Draft::File#freeze! hands
      # back the finished, shareable file.
      #
      # ```ruby
      # file = Schema::File.draft("shop.proto", package: "shop", syntax: :proto3)
      # file.message("Item") do |m|
      #   m.field "name", 1, :string
      #   m.field "price_cents", 2, :int64, optional: true
      #   m.map "stock", 3, key: :string, value: :int32
      # end
      # file.resolve(pool)
      # file.freeze!  # => #<Protostar::Schema::File shop.proto>
      # ```
      #
      # - `name`: the file name as imported
      # - `syntax`: :proto2, :proto3 or :editions; nil is proto2, and
      #   unlike an explicit :proto2 leaves `syntax` out of the FileDescriptorProto, as protoc does
      # - `edition`: e.g. :EDITION_2023; implies :editions
      # - `dependencies`: imported file names
      # - `public_dependencies`: names or indexes of `import public` files
      # - `option_dependencies`: `import option` file names
      # - `options`: the file's options
      #: (String name, ?package: String?, ?syntax: Symbol?, ?edition: (Symbol | Integer)?, ?dependencies: Array[String], ?public_dependencies: Array[(String | Integer)], ?weak_dependencies: Array[(String | Integer)], ?option_dependencies: Array[String], ?options: Hash[untyped, untyped]?) -> Draft::File
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
