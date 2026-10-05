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

        # @api private
        def initialize(hash)
          @path = Freezer.call(hash[:path] || [])
          @span = Freezer.call(hash[:span] || [])
          @leading_comments = Freezer.call(hash[:leading_comments])
          @trailing_comments = Freezer.call(hash[:trailing_comments])
          @leading_detached_comments = Freezer.call(hash[:leading_detached_comments] || [])
        end

        # @return [Hash]
        def to_h
          h = {}
          h[:path] = @path unless @path.empty?
          h[:span] = @span unless @span.empty?
          h[:leading_comments] = @leading_comments if @leading_comments
          h[:trailing_comments] = @trailing_comments if @trailing_comments
          h[:leading_detached_comments] = @leading_detached_comments unless @leading_detached_comments.empty?
          h
        end
      end

      # @return [Array<Location>]
      attr_reader :locations

      # @param hash [Hash] a `SourceCodeInfo` hash (`{location: [...]}`)
      def initialize(hash)
        raise Error, "source_code_info must be a Hash, got #{hash.class}" unless hash.is_a?(Hash)
        @locations = (hash[:location] || []).map { |loc| Location.new(loc) }.freeze
        @by_path = {}
        @locations.each { |loc| @by_path[loc.path] ||= loc }
        @by_path.freeze
      end

      # @param path [Array<Integer>]
      # @return [Location, nil] the first location recorded for the path
      def location(path)
        @by_path[path]
      end

      # @return [Hash]
      def to_h
        @locations.empty? ? {} : {location: @locations.map(&:to_h)}
      end
    end
  end
end
