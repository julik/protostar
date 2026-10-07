# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# Minitest 5 only warns about assert_equal with a nil expectation (Minitest 6
# fails it), and a warning scrolls by unnoticed in a parallel run. The parser
# cases are where nil expectations come from, so run them on their own and
# keep their stderr empty.
class CompilerParserCasesStderrTest < Minitest::Test
  def test_parser_cases_print_nothing_to_stderr
    root = TestSupport::ROOT
    file = File.join(root, "test", "compiler", "parser_cases_test.rb")
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(root, "lib"), "-I", File.join(root, "test"), file)
    assert status.success?, out
    assert_empty err
  end
end
