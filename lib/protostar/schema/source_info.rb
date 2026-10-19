# frozen_string_literal: true

module Protostar
  module Schema
    # A file's `source_code_info`, kept verbatim
    class SourceInfo
      # One `SourceCodeInfo.Location`
      class Location
        # The descriptor path, e.g. [4, 0, 2, 1] for message 0, field 1.
        attr_reader :path #: Array[Integer]
        # [start_line, start_column, (end_line,) end_column], zero-based.
        attr_reader :span #: Array[Integer]
        attr_reader :leading_comments #: String?
        attr_reader :trailing_comments #: String?
        attr_reader :leading_detached_comments #: Array[String]

        #: (path: Array[Integer], span: Array[Integer], ?leading_comments: String?, ?trailing_comments: String?, ?leading_detached_comments: Array[String]) -> void
        def initialize(path:, span:, leading_comments: nil, trailing_comments: nil, leading_detached_comments: [])
          @path = Freezer.call(path)
          @span = Freezer.call(span)
          @leading_comments = Freezer.call(leading_comments)
          @trailing_comments = Freezer.call(trailing_comments)
          @leading_detached_comments = Freezer.call(leading_detached_comments)
          freeze
        end
      end

      attr_reader :locations #: Array[Location]

      # - `locations`: in protoc's order
      #: (Array[Location] locations) -> void
      def initialize(locations)
        @locations = locations.dup.freeze
        @by_path = {}
        @locations.each { |loc| @by_path[loc.path] ||= loc }
        @by_path.freeze
      end

      # Returns the first location recorded for the path.
      #: (Array[Integer] path) -> Location?
      def location(path)
        @by_path[path]
      end
    end
  end
end
