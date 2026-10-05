# frozen_string_literal: true

module Protostar
  module Schema
    # A file's `source_code_info`, kept verbatim
    class SourceInfo
      # One `SourceCodeInfo.Location`
      class Location
        # @return [Array<Integer>] the descriptor path, e.g. [4, 0, 2, 1] for message 0, field 1
        attr_reader :path
        # @return [Array<Integer>] [start_line, start_column, (end_line,) end_column], zero-based
        attr_reader :span
        # @return [String, nil]
        attr_reader :leading_comments
        # @return [String, nil]
        attr_reader :trailing_comments
        # @return [Array<String>]
        attr_reader :leading_detached_comments

        # @param path [Array<Integer>]
        # @param span [Array<Integer>]
        # @param leading_comments [String, nil]
        # @param trailing_comments [String, nil]
        # @param leading_detached_comments [Array<String>]
        def initialize(path:, span:, leading_comments: nil, trailing_comments: nil, leading_detached_comments: [])
          @path = Freezer.call(path)
          @span = Freezer.call(span)
          @leading_comments = Freezer.call(leading_comments)
          @trailing_comments = Freezer.call(trailing_comments)
          @leading_detached_comments = Freezer.call(leading_detached_comments)
          freeze
        end
      end

      # @return [Array<Location>]
      attr_reader :locations

      # @param locations [Array<Location>] in protoc's order
      def initialize(locations)
        @locations = locations.dup.freeze
        @by_path = {}
        @locations.each { |loc| @by_path[loc.path] ||= loc }
        @by_path.freeze
      end

      # @param path [Array<Integer>]
      # @return [Location, nil] the first location recorded for the path
      def location(path)
        @by_path[path]
      end
    end
  end
end
