# frozen_string_literal: true

module Protostar
  module Lint
    # The `lint:` section of `.protostar.yml`:
    #
    # ```ruby
    # lint:
    #   rules: [default]                  # sets, categories or rule ids
    #   except: [PACKAGE_VERSION_SUFFIX]
    #   ignore: ["vendor/**"]             # relative to the file's directory
    #   allow_comment_directives: true
    # ```
    class Config
      FILE_NAME = ".protostar.yml"
      KEYS = %w[rules except ignore allow_comment_directives].freeze

      attr_reader :rules #: Array[String]
      attr_reader :except #: Array[String]
      # Globs.
      attr_reader :ignore #: Array[String]
      # The directory `ignore` globs are relative to.
      attr_reader :root #: String
      # The file read, nil for the defaults.
      attr_reader :file #: String?

      # The first `.protostar.yml` next to an input (a directory or a file's
      # directory), else in the current directory, else the defaults
      #: (Array[String] inputs, ?cwd: String) -> Config
      def self.find(inputs, cwd: Dir.pwd)
        dirs = inputs.map { |i| ::File.directory?(i) ? i : ::File.dirname(i) } + [cwd]
        dirs.each do |dir|
          path = ::File.join(dir, FILE_NAME)
          return load(path) if ::File.file?(path)
        end
        new({}, root: cwd)
      end

      # Raises Error when it is not YAML, or the `lint:` section has an unknown key.
      #: (String path) -> Config
      def self.load(path)
        require "yaml"
        data = YAML.safe_load_file(path) || {}
        raise Error, "#{path}: expected a mapping" unless data.is_a?(Hash)
        section = data.fetch("lint", {}) || {}
        raise Error, "#{path}: `lint` must be a mapping" unless section.is_a?(Hash)
        unknown = section.keys - KEYS
        raise Error, "#{path}: unknown lint setting #{unknown.join(", ")} (known: #{KEYS.join(", ")})" unless unknown.empty?
        new(section, root: ::File.dirname(::File.expand_path(path)), file: path)
      rescue Psych::Exception => e
        raise Error, "#{path}: #{e.message}"
      end

      def initialize(section, root:, file: nil)
        @rules = list(section["rules"]) || ["default"]
        @except = list(section["except"]) || []
        @ignore = list(section["ignore"]) || []
        @directives = section.fetch("allow_comment_directives", true) != false
        @root = root
        @file = file
      end

      #: () -> bool
      def allow_comment_directives?
        @directives
      end

      # - `path`: a file found while walking a directory
      #
      # Returns whether an `ignore` glob matches it or a directory above it.
      #: (String path) -> bool
      def ignored?(path)
        return false if @ignore.empty?
        rel = relative(::File.expand_path(path))
        candidates = [rel]
        dir = ::File.dirname(rel)
        until dir == "." || dir == "/"
          candidates << dir
          dir = ::File.dirname(dir)
        end
        @ignore.any? do |glob|
          candidates.any? { |c| ::File.fnmatch?(glob, c, ::File::FNM_PATHNAME | ::File::FNM_EXTGLOB) }
        end
      end

      private

      def list(value)
        return nil if value.nil?
        Array(value).flat_map { |v| v.to_s.split(",") }.map(&:strip).reject(&:empty?)
      end

      def relative(path)
        root = ::File.expand_path(@root)
        path.start_with?("#{root}/") ? path.delete_prefix("#{root}/") : path
      end
    end
  end
end
