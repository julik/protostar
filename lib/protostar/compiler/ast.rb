# frozen_string_literal: true

module Protostar
  class Compiler
    # The parse tree of a `.proto` file. It is shaped like the
    # `FileDescriptorProto` protoc's parser produces before linking: names as
    # written, options uninterpreted, map entries and groups already expanded
    # into nested messages. {Node#to_h} gives exactly that parser output.
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
        # Linker state: full name and source path here, resolutions on subclasses
        attr_accessor :full_name, :path

        def initialize
          @positions = {}
        end

        # @return [Array(Integer, Integer), nil]
        def position(kind)
          @positions[kind]
        end

        private

        def put(h, key, value)
          h[key] = value unless value.nil?
        end

        def put_list(h, key, list)
          h[key] = list.map(&:to_h) unless list.empty?
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

        # @return [Hash] the parser's FileDescriptorProto, without source info
        def to_h
          h = {}
          put(h, :name, @name)
          put(h, :package, @package)
          h[:dependency] = @dependency.dup unless @dependency.empty?
          h[:public_dependency] = @public_dependency.dup unless @public_dependency.empty?
          h[:weak_dependency] = @weak_dependency.dup unless @weak_dependency.empty?
          h[:option_dependency] = @option_dependency.dup unless @option_dependency.empty?
          put_list(h, :message_type, @message_type)
          put_list(h, :enum_type, @enum_type)
          put_list(h, :service, @service)
          put_list(h, :extension, @extension)
          put(h, :options, @options&.to_h)
          put(h, :syntax, @syntax)
          put(h, :edition, @edition)
          h
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

        def to_h
          h = @known.dup
          h[:uninterpreted_option] = @uninterpreted.map(&:to_h) unless @uninterpreted.empty?
          h
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

        def to_h
          h = {name: @name.map { |part, ext| {name_part: part, is_extension: ext} }}
          h[@value_kind] = @value if @value_kind
          h
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

        def to_h
          h = {}
          put(h, :name, @name)
          put_list(h, :field, @field)
          put_list(h, :extension, @extension)
          put_list(h, :nested_type, @nested_type)
          put_list(h, :enum_type, @enum_type)
          put_list(h, :extension_range, @extension_range)
          put_list(h, :oneof_decl, @oneof_decl)
          put(h, :options, @options&.to_h)
          put_list(h, :reserved_range, @reserved_range)
          h[:reserved_name] = @reserved_name.dup unless @reserved_name.empty?
          put(h, :visibility, @visibility)
          h
        end
      end

      # A field or an extension
      class Field < Node
        attr_accessor :name, :number, :label, :type, :type_name, :extendee, :default_value, :json_name,
          :oneof_index, :proto3_optional, :options
        # Set by the linker: the declaring message (nil at file level), whether
        # this is an extension, and what the type and extendee resolved to
        attr_accessor :parent, :extension, :resolved_type, :resolved_extendee, :index

        def to_h
          h = {}
          put(h, :name, @name)
          put(h, :extendee, @extendee)
          put(h, :number, @number)
          put(h, :label, @label)
          put(h, :type, @type)
          put(h, :type_name, @type_name)
          put(h, :default_value, @default_value)
          put(h, :options, @options&.to_h)
          put(h, :oneof_index, @oneof_index)
          put(h, :json_name, @json_name)
          h[:proto3_optional] = true if @proto3_optional
          h
        end
      end

      # A `oneof` declaration
      class Oneof < Node
        attr_accessor :name, :options
        attr_accessor :parent, :index

        def to_h
          h = {}
          put(h, :name, @name)
          put(h, :options, @options&.to_h)
          h
        end
      end

      # An `extensions` range (end exclusive) or a `reserved` range
      # (end exclusive for messages, inclusive for enums)
      class Range < Node
        attr_accessor :start, :end, :options
        attr_accessor :parent, :index

        def to_h
          h = {}
          put(h, :start, @start)
          put(h, :end, @end)
          put(h, :options, @options&.to_h)
          h
        end
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

        def to_h
          h = {}
          put(h, :name, @name)
          put_list(h, :value, @value)
          put(h, :options, @options&.to_h)
          put_list(h, :reserved_range, @reserved_range)
          h[:reserved_name] = @reserved_name.dup unless @reserved_name.empty?
          put(h, :visibility, @visibility)
          h
        end
      end

      # An enum value
      class EnumValue < Node
        attr_accessor :name, :number, :options
        attr_accessor :parent, :index

        def to_h
          h = {}
          put(h, :name, @name)
          put(h, :number, @number)
          put(h, :options, @options&.to_h)
          h
        end
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

        def to_h
          h = {}
          put(h, :name, @name)
          put_list(h, :method, @rpcs)
          put(h, :options, @options&.to_h)
          h
        end
      end

      # An rpc
      class Method < Node
        attr_accessor :name, :input_type, :output_type, :options, :client_streaming, :server_streaming
        attr_accessor :parent, :index, :resolved_input, :resolved_output

        def to_h
          h = {}
          put(h, :name, @name)
          put(h, :input_type, @input_type)
          put(h, :output_type, @output_type)
          put(h, :options, @options&.to_h)
          h[:client_streaming] = true if @client_streaming
          h[:server_streaming] = true if @server_streaming
          h
        end
      end
    end
  end
end
