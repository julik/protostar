# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # FILE_LOWER_SNAKE_CASE: A file name that is not lower_snake_case
      class FileLowerSnakeCase < Rule
        REASON = "Generated file and module names follow the .proto's name; lower_snake_case works on every file system and in every language."
        EXPLANATION = <<~TEXT
          Code generators derive file, module and class names from the `.proto` file's name. Mixed case breaks on
          case-insensitive file systems and reads oddly as a Python module or Go file.

              acme/UserProfile.proto

          Fix: rename the file to `acme/user_profile.proto` and update the imports.
        TEXT

        def check
          base = ::File.basename(context.name, ".proto")
          return if Naming.lower_snake?(base)
          add("file name `#{::File.basename(context.name)}` is not lower_snake_case", [],
            help: "rename the file `#{Naming.lower_snake(base)}.proto`")
        end
      end
    end
  end
end
