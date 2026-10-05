# frozen_string_literal: true

module Protostar
  class Compiler
    # The parse tree of a `.proto` file. It holds what protoc's parser puts
    # in a `FileDescriptorProto` before linking: names as written, options
    # uninterpreted, map entries, groups and the synthetic oneofs of proto3
    # `optional` fields already expanded, as protoc's parser expands them.
    #
    # Every node records where its parts start in {Node#positions}, keyed by
    # the error locations protoc's DescriptorPool reports against (`:name`,
    # `:number`, `:type`, `:extendee`, `:default_value`, `:option_name`,
    # `:option_value`, `:input_type`, `:output_type`, `:editions`, `:other`),
    # each a 0-based `[line, column]`.
    module AST
      # @api private
      class Node
        # @return [Hash{Symbol => Array(Integer, Integer)}]
        attr_reader :positions
        # Linker state: full name and source path
        attr_accessor :full_name, :path

        def initialize
          @positions = {}
        end

        # @return [Array(Integer, Integer), nil]
        def position(kind)
          @positions[kind]
        end
      end

      # A whole `.proto` file
      class File < Node
        attr_accessor :name, :package, :syntax, :edition, :options
        attr_reader :dependency, :public_dependency, :weak_dependency, :option_dependency,
          :message_type, :enum_type, :service, :extension, :import_positions
        # @return [Array<SourceInfo::Location>] in protoc's order
        attr_accessor :locations

        def initialize
          super
          @dependency = []
          @public_dependency = []
          @weak_dependency = []
          @option_dependency = []
          @message_type = []
          @enum_type = []
          @service = []
          @extension = []
          @import_positions = {}
          @locations = []
        end
      end

      # The options of one element: the uninterpreted `option` statements and
      # the few options protoc's parser sets itself (`map_entry`)
      class Options
        # @return [Array<Option>]
        attr_reader :uninterpreted
        # @return [Hash] options set directly, e.g. `{map_entry: true}`
        attr_reader :known

        def initialize
          @uninterpreted = []
          @known = {}
        end

        def empty?
          @uninterpreted.empty? && @known.empty?
        end

        # A copy whose options carry no positions, as protoc's message copy
        # leaves them out of its location table
        def copy
          other = Options.new
          other.known.merge!(@known)
          @uninterpreted.each { |o| other.uninterpreted << o.copy }
          other
        end
      end

      # One uninterpreted option: `(my.ext).sub.field = value`
      class Option < Node
        # @return [Array<Array(String, Boolean)>] name parts and whether each is an extension
        attr_reader :name
        # @return [Symbol, nil] which value field is set: :identifier_value,
        #   :positive_int_value, :negative_int_value, :double_value,
        #   :string_value or :aggregate_value
        attr_accessor :value_kind
        attr_accessor :value

        def initialize
          super
          @name = []
        end

        def copy
          other = Option.new
          @name.each { |part| other.name << part }
          other.value_kind = @value_kind
          other.value = @value
          other
        end

        # @return [String] the name as protoc prints it in errors: `(a.b).c`
        def display_name
          @name.map { |part, ext| ext ? "(#{part})" : part }.join(".")
        end
      end

      # A message, including synthesized map entries and group bodies
      class Message < Node
        attr_accessor :name, :options, :visibility
        attr_accessor :parent, :index
        attr_reader :field, :nested_type, :enum_type, :extension_range, :extension, :oneof_decl,
          :reserved_range, :reserved_name

        def initialize
          super
          @field = []
          @nested_type = []
          @enum_type = []
          @extension_range = []
          @extension = []
          @oneof_decl = []
          @reserved_range = []
          @reserved_name = []
        end
      end

      # A field or an extension
      class Field < Node
        attr_accessor :name, :number, :label, :type, :type_name, :extendee, :default_value, :json_name,
          :oneof_index, :proto3_optional, :options
        # Set by the linker: the declaring message (nil at file level), whether
        # this is an extension, and its index
        attr_accessor :parent, :extension, :index
      end

      # A `oneof` declaration
      class Oneof < Node
        attr_accessor :name, :options
        attr_accessor :parent, :index
      end

      # An `extensions` range (end exclusive) or a `reserved` range
      # (end exclusive for messages, inclusive for enums)
      class Range < Node
        attr_accessor :start, :end, :options
        attr_accessor :parent, :index
      end

      # An enum
      class Enum < Node
        attr_accessor :name, :options, :visibility
        attr_accessor :parent, :index
        attr_reader :value, :reserved_range, :reserved_name

        def initialize
          super
          @value = []
          @reserved_range = []
          @reserved_name = []
        end
      end

      # An enum value
      class EnumValue < Node
        attr_accessor :name, :number, :options
        attr_accessor :parent, :index
      end

      # A service
      class Service < Node
        attr_accessor :name, :options
        attr_accessor :index
        attr_reader :rpcs

        def initialize
          super
          @rpcs = []
        end
      end

      # An rpc
      class Method < Node
        attr_accessor :name, :input_type, :output_type, :options, :client_streaming, :server_streaming
        attr_accessor :parent, :index
      end
    end
  end
end
