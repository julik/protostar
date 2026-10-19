# frozen_string_literal: true

module Protostar
  class Compiler
    # Builds `SourceCodeInfo` the way protoc does: the parser opens a
    # Recorder for every element as it starts reading it, so locations come
    # out in pre-order with protoc's paths and spans, and comments are
    # attached at the end of each declaration. After option interpretation
    # {.rewrite_option_paths} moves option locations from
    # `uninterpreted_option` paths to the paths of the options they set.
    module SourceInfo # :nodoc: all
      # A `SourceCodeInfo.Location` under construction
      class Location
        attr_accessor :path, :span, :leading_comments, :trailing_comments, :leading_detached_comments

        def initialize(path, span)
          @path = path
          @span = span
          @leading_comments = nil
          @trailing_comments = nil
          @leading_detached_comments = []
        end

        def dup_with_path(path)
          copy = Location.new(path, @span.dup)
          copy.leading_comments = @leading_comments
          copy.trailing_comments = @trailing_comments
          copy.leading_detached_comments = @leading_detached_comments.dup
          copy
        end

        # Returns the finished location, comments as UTF-8.
        #: () -> Schema::SourceInfo::Location
        def to_schema
          Schema::SourceInfo::Location.new(path: @path, span: @span, leading_comments: utf8(@leading_comments),
            trailing_comments: utf8(@trailing_comments),
            leading_detached_comments: @leading_detached_comments.map { |c| utf8(c) })
        end

        private

        def utf8(text)
          text&.dup&.force_encoding(Encoding::UTF_8)
        end
      end

      # protoc's Parser::LocationRecorder. It starts at the current token when
      # created and, unless ended explicitly, ends at the previous token when
      # #finished.
      class Recorder
        attr_reader :location #: Location
        # Where the location was added.
        attr_reader :target #: Array[Location]

        # - `path`: the parent's path plus this element's components
        #: (Lexer lexer, Array[Integer] path, Array[Location] target) -> void
        def initialize(lexer, path, target)
          @lexer = lexer
          @target = target
          token = lexer.current
          @location = Location.new(path, [token.line, token.column])
          target << @location
        end

        # Returns a child location, its path extended by `components`.
        #: (*untyped components, ?target: untyped) -> Recorder
        def child(*components, target: @target)
          Recorder.new(@lexer, @location.path + components, target)
        end

        def add_path(component)
          @location.path << component
        end

        def path_size
          @location.path.size
        end

        def start_at(token)
          @location.span[0] = token.line
          @location.span[1] = token.column
        end

        def start_at_recorder(other)
          @location.span[0] = other.location.span[0]
          @location.span[1] = other.location.span[1]
        end

        def end_at(token)
          @location.span << token.line if token.line != @location.span[0]
          @location.span << token.end_column
        end

        # The LocationRecorder destructor
        def finish
          end_at(@lexer.previous) if @location.span.size <= 2
        end

        # Records where this element starts, for diagnostics against `node`
        def record_legacy(node, kind)
          node.positions[kind] = [@location.span[0], @location.span[1]]
        end

        #: () -> [Integer, Integer]
        def start
          [@location.span[0], @location.span[1]]
        end

        def attach_comments(leading, trailing, detached)
          @location.leading_comments = leading.dup unless leading.empty?
          @location.trailing_comments = trailing.dup unless trailing.empty?
          detached.each { |c| @location.leading_detached_comments << c }
          detached.clear
        end
      end

      # Where the shortest location starting at a position ends: the extent of
      # the element whose name, number or type is reported there
      #
      # Returns 0-based line and column just past the end.
      #: (Array[Location] locations, untyped line, untyped column) -> [Integer, Integer]?
      def self.extent(locations, line, column)
        best = nil
        locations.each do |loc|
          span = loc.span
          next unless span[0] == line && span[1] == column && span.size >= 3
          finish = (span.size == 4) ? [span[2], span[3]] : [span[0], span[2]]
          best = finish if best.nil? || (finish <=> best) < 0
        end
        best
      end

      # OptionInterpreter::UpdateSourceCodeInfo: the location of each
      # interpreted option takes the path of the option it set, and the
      # locations nested under it (name parts, values) are dropped
      #
      # - `interpreted`: uninterpreted_option path to option path
      #: (Array[Location] locations, Hash[Array[Integer], Array[Integer]] interpreted) -> Array[Location]
      def self.rewrite_option_paths(locations, interpreted)
        return locations if interpreted.empty?
        out = []
        match_src = nil
        locations.each do |loc|
          if match_src
            next if loc.path.size >= match_src.size && loc.path[0, match_src.size] == match_src
            match_src = nil
          end
          dest = interpreted[loc.path]
          if dest.nil?
            out << loc
            next
          end
          match_src = loc.path
          out << loc.dup_with_path(dest.dup)
        end
        out
      end
    end
  end
end
