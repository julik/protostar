# frozen_string_literal: true

require "test_helper"
require_relative "validation_cases"

# One snippet per rule protoc enforces, compiled the way protoc's command line
# compiles a file, compared line for line with what protoc 36.2 printed for
# it (recorded in validation_cases.rb by script/record_validation_cases.rb).
class CompilerValidationTest < Minitest::Test
  ValidationCases::CASES.each do |name, c|
    define_method(:"test_#{name.gsub(/\W+/, "_")}") do
      compiler = Protostar::Compiler.new
      main = c[:files].keys.first
      begin
        compiler.compile([main], sources: c[:files])
        assert c[:success], "protoc rejected this, we accepted it"
        diagnostics = compiler.diagnostics
      rescue Protostar::Compiler::Error => e
        refute c[:success], "protoc accepted this, we rejected it: #{e.message}"
        diagnostics = e.diagnostics
        assert_equal diagnostics.join("\n"), e.message
      end
      assert_equal c[:protoc], diagnostics.map(&:to_s)
    end
  end

  def test_diagnostics_carry_positions
    error = assert_raises(Protostar::Compiler::Error) do
      Protostar::Compiler.new.compile(["a.proto"], sources: {"a.proto" => "syntax = \"proto3\";\nmessage A {\n  B b = 1;\n}\n"})
    end
    diagnostic = error.diagnostics.first
    assert_equal ["a.proto", 3, 3, "\"B\" is not defined."], [diagnostic.file, diagnostic.line, diagnostic.column, diagnostic.message]
    assert diagnostic.error?
    assert_equal "a.proto:3:3: \"B\" is not defined.", diagnostic.to_s
  end
end
