# frozen_string_literal: true

require "test_helper"
require_relative "rule_cases"

# One golden per rule: what it reports on files that break it, rendered and
# as JSON, and nothing on files that do not
class LintRulesTest < Minitest::Test
  GOLDENS = File.join(__dir__, "goldens")

  LintRuleCases::CASES.each do |id, c|
    define_method(:"test_#{id.downcase}") do
      text, json = LintRuleCases.outputs(id, c[:bad])
      assert_equal File.read(File.join(GOLDENS, "#{id}.txt")), text, "#{id} rendered (ruby script/lint_goldens.rb rewrites it)"
      assert_equal File.read(File.join(GOLDENS, "#{id}.jsonl")), json, "#{id} as JSON"
      assert_empty LintRuleCases.findings(id, c[:good]).map(&:title), "#{id} on a file that follows it"
    end
  end

  def test_every_rule_has_a_case_a_class_and_an_explanation
    assert_equal Protostar::Lint::RULES.keys.sort, LintRuleCases::CASES.keys.sort
    codes = Protostar::Lint::RULES.values.map(&:first)
    assert_equal codes.uniq, codes
    Protostar::Lint::RULES.each_key do |id|
      rule = Protostar::Lint.rule_class(id)
      assert_equal id, rule.id
      assert_match(/\A[A-Z`].*\.\z/, rule.reason, id)
      assert_includes rule.explanation, "Fix", id
    end
  end

  def test_sets
    minimal = Protostar::Lint.select(["minimal"])
    default = Protostar::Lint.select(["default"])
    strict = Protostar::Lint.select(["strict"])
    assert_equal [11, 28, 37], [minimal.size, default.size, strict.size]
    assert_empty minimal - default
    assert_empty default - strict
    assert_equal %w[COMMENT_MESSAGE COMMENT_FIELD COMMENT_ENUM COMMENT_ENUM_VALUE COMMENT_SERVICE COMMENT_RPC],
      Protostar::Lint.select(["documentation"])
    assert_equal minimal - ["FIELD_NOT_REQUIRED"], Protostar::Lint.select(["minimal"], except: ["W0101"])
    assert_equal %w[FIELD_NOT_REQUIRED PACKAGE_VERSION_SUFFIX], Protostar::Lint.select(%w[package_version_suffix W0101])
    assert_raises(Protostar::Lint::Error) { Protostar::Lint.select(["everything"]) }
  end

  def test_naming
    naming = Protostar::Lint::Naming
    assert_equal %w[foo_bar http_server field1], %w[fooBar HTTPServer field1].map { |n| naming.lower_snake(n) }
    assert_equal "COLOR_RED", naming.upper_snake("colorRed")
    assert_equal "UserProfile", naming.pascal("user_profile")
    assert naming.lower_snake?("field_1")
    refute naming.lower_snake?("foo__bar")
    refute naming.upper_snake?("Color_RED")
  end
end
