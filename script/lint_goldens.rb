# frozen_string_literal: true

# Rewrites test/lint/goldens/<RULE>.txt and .jsonl from test/lint/rule_cases.rb.
# Read the diff before committing: the goldens are what the tests pin.
#
#   ruby script/lint_goldens.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "protostar"
require_relative "../test/lint/rule_cases"

dir = File.expand_path("../test/lint/goldens", __dir__)
Dir.mkdir(dir) unless Dir.exist?(dir)
LintRuleCases::CASES.each do |id, c|
  text, json = LintRuleCases.outputs(id, c[:bad])
  abort "#{id}: the bad case finds nothing" if text.empty?
  File.write(File.join(dir, "#{id}.txt"), text)
  File.write(File.join(dir, "#{id}.jsonl"), json)
end
puts "#{LintRuleCases::CASES.size} rules"
