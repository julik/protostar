# frozen_string_literal: true

module Protostar
  class Compiler
    # The checks protoc runs once a file is built (DescriptorBuilder's
    # ValidateOptions phase and what follows it), against the built
    # {Schema::File} with positions from the AST.
    #
    # @api private
    class Validator
      def initialize(linker)
        @linker = linker
        @file = linker.file
      end

      def validate
        unused_imports
      end

      # The command-line interface's checks over a successfully built input file
      def self.cli_checks(file, compiler, run)
      end

      private

      def unused_imports
        return if @linker.errors?
        @linker.table.unused.each do |name|
          @linker.import_warning(name, "Import #{name} is unused.")
        end
      end
    end
  end
end
