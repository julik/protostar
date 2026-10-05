# frozen_string_literal: true

module Protostar
  class Compiler
    # Code generators. Each takes built {Schema::File}s and returns
    # `{output path => contents}`.
    module Emitters
      # Raised when a file cannot be emitted (protoc's generator errors)
      class Error < Compiler::Error
        def initialize(message)
          super([Diagnostic.new(nil, nil, nil, message)])
        end
      end

      # The files whose generated Ruby ships with protostar under
      # `protostar/google/protobuf/`, with constants under
      # `Protostar::Google::Protobuf`
      BOOTSTRAP = %w[
        google/protobuf/descriptor.proto google/protobuf/compiler/plugin.proto google/protobuf/any.proto
        google/protobuf/api.proto google/protobuf/duration.proto google/protobuf/empty.proto
        google/protobuf/field_mask.proto google/protobuf/source_context.proto google/protobuf/struct.proto
        google/protobuf/timestamp.proto google/protobuf/type.proto google/protobuf/wrappers.proto
      ].freeze

      # The Ruby module the bootstrap's `google.protobuf` package lives in
      BOOTSTRAP_NAMESPACE = "Protostar::Google::Protobuf"

      # protoc's Ruby generator naming rules (ruby_generator.cc), which grpc
      # stubs and application code depend on
      module Naming
        # Characters protoc refuses in `ruby_package`
        BANNED_RUBY_PACKAGE = ";`{}()'\"$#=<>|&[]/\\@%\n\r!?*~^,\0"

        module_function

        # "foo/bar.proto" to "foo/bar_pb"
        def require_name(proto_file)
          dot = proto_file.rindex(".")
          "#{dot ? proto_file[0, dot] : proto_file}_pb"
        end

        # snake_case package part to a module name: "foo_bar" to "FooBar"
        def package_to_module(name)
          out = +""
          upper = true
          name.each_char do |c|
            if c == "_"
              upper = true
            else
              out << (upper ? upcase(c) : c)
              upper = false
            end
          end
          out
        end

        # A message or enum name as a Ruby constant: first letter
        # capitalised, "PB_" prefixed when it does not start with a letter
        def rubify_constant(name)
          return name if name.empty?
          first = name[0]
          if first.between?("a", "z")
            upcase(first) + name[1..]
          elsif !first.between?("A", "Z")
            "PB_#{name}"
          else
            name
          end
        end

        # The modules a file's constants live in, outermost first
        # @param file [Schema::File]
        # @param namespace [String, nil] overrides the package and `ruby_package`
        # @return [Array<String>]
        def module_path(file, namespace = nil)
          return namespace.split("::") if namespace
          if file.options.key?(:ruby_package)
            package = file.options[:ruby_package]
            return package.split("::") if package.include?("::")
          else
            package = file.package
          end
          return [] if package.empty?
          package.split(".", -1).map { |part| package_to_module(part) }
        end

        # protoc's check on `ruby_package`
        # @raise [Emitters::Error]
        def check_ruby_package(file)
          return unless file.options.key?(:ruby_package)
          file.options[:ruby_package].each_char do |c|
            next unless BANNED_RUBY_PACKAGE.include?(c)
            raise Emitters::Error, "Invalid character in ruby_package option: character '#{c}' is not allowed " \
              "because it could enable code injection."
          end
        end

        # The constant path of a message or enum relative to its file's module
        # @param descriptor [Schema::Message, Schema::Enum]
        def relative_constant(descriptor)
          names = []
          d = descriptor
          while d
            names.unshift(rubify_constant(d.name))
            d = d.containing_message
          end
          names.join("::")
        end

        def upcase(c)
          c.between?("a", "z") ? c.upcase : c
        end
      end

      # Ruby source for literal values: Strings as UTF-8 text or binary with
      # `.b`, floats exactly, Hashes and Arrays broken over lines when long
      module Literal
        WIDTH = 100
        ESCAPES = {"\n" => "\\n", "\t" => "\\t", "\r" => "\\r", "\"" => "\\\"", "\\" => "\\\\", "\e" => "\\e",
                   "\a" => "\\a", "\b" => "\\b", "\f" => "\\f", "\v" => "\\v"}.freeze

        module_function

        # @param value [Object]
        # @param indent [Integer] the indentation of the line the literal is on
        # @param start [Integer] the column the literal starts on
        # @return [String] on one line when it fits, otherwise one element per line
        def call(value, indent = 0, start = indent)
          flat = flat(value)
          return flat if start + flat.size <= WIDTH || !(value.is_a?(Hash) || value.is_a?(Array)) || value.empty?
          pad = " " * (indent + 2)
          items = if value.is_a?(Array)
            value.map { |v| pad + call(v, indent + 2) }
          else
            value.map { |k, v| pad + key(k) + call(v, indent + 2, indent + 2 + key(k).size) }
          end
          open, close = value.is_a?(Array) ? ["[", "]"] : ["{", "}"]
          "#{open}\n#{items.join(",\n")}\n#{" " * indent}#{close}"
        end

        def flat(value)
          case value
          when Hash then value.empty? ? "{}" : "{#{value.map { |k, v| key(k) + flat(v) }.join(", ")}}"
          when Array then "[#{value.map { |v| flat(v) }.join(", ")}]"
          when String then string(value)
          when Symbol then value.inspect
          when Float then float(value)
          when Integer, true, false, nil then value.inspect
          when Range then "#{value.begin}..#{value.end}"
          else raise ArgumentError, "no literal for #{value.class}"
          end
        end

        def key(k)
          if k.is_a?(Symbol) && /\A[A-Za-z_][A-Za-z0-9_]*\z/.match?(k)
            "#{k}: "
          else
            "#{flat(k)} => "
          end
        end

        def float(value)
          return "Float::NAN" if value.nan?
          return (value > 0) ? "Float::INFINITY" : "-Float::INFINITY" if value.infinite?
          value.inspect
        end

        # A double-quoted literal; binary Strings, and Strings that are not
        # valid UTF-8, are escaped byte by byte and marked `.b`
        def string(value)
          binary = value.encoding == Encoding::BINARY || !value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          out = +"\""
          if binary
            value.each_byte { |b| out << byte(b) }
            out << "\".b"
          else
            text = (value.encoding == Encoding::UTF_8) ? value : value.dup.force_encoding(Encoding::UTF_8)
            text.each_char { |c| out << char(c) }
            out << "\""
          end
          out
        end

        def byte(b)
          c = b.chr
          if (escaped = ESCAPES[c])
            escaped
          elsif b < 0x20 || b >= 0x7F
            format("\\x%02X", b)
          elsif c == "#"
            "\\#"
          else
            c
          end
        end

        def char(c)
          if (escaped = ESCAPES[c])
            escaped
          elsif c == "#"
            "\\#"
          elsif c.ord < 0x20 || c.ord == 0x7F
            format("\\x%02X", c.ord)
          elsif c.ord >= 0x80 && !printable?(c)
            format("\\u{%X}", c.ord)
          else
            c
          end
        end

        # Formatting and line-breaking code points are escaped so that a
        # generated line never breaks or reorders visually
        def printable?(c)
          !/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Cs}\p{Co}\p{Cn}]/.match?(c)
        end
      end
    end
  end
end

require_relative "emitters/ruby"
require_relative "emitters/descriptor_set"
