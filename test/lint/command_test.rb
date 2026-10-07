# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "fileutils"

# `protostar lint`: inputs, rule selection, configuration, directives,
# formats, fixes and exit codes
class LintCommandTest < Minitest::Test
  EXE = File.join(TestSupport::ROOT, "exe/protostar")

  CLEAN = <<~PROTO
    syntax = "proto3";

    package acme.v1;

    message User {
      string id = 1;
    }
  PROTO

  def lint(*args)
    out = StringIO.new
    err = StringIO.new
    status = Protostar::Lint::Command.new(out, err).run(args)
    [out.string, err.string, status]
  end

  def tree(files)
    dir = tmpdir
    files.each do |path, source|
      FileUtils.mkdir_p(File.join(dir, File.dirname(path)))
      File.write(File.join(dir, path), source)
    end
    dir
  end

  def rules_in(out)
    out.lines.map { |l| JSON.parse(l)["rule"] || JSON.parse(l)["code"] }
  end

  def test_clean_file_exits_zero
    dir = tree("acme/v1/user.proto" => CLEAN)
    out, err, status = lint(dir)
    assert_equal ["1 file: 0 errors, 0 warnings\n", "", 0], [out, err, status]
  end

  def test_warnings_exit_one_unless_warnings_ok
    dir = tree("acme/v1/user.proto" => CLEAN.sub("string id", "string userId"))
    _, _, status = lint(dir)
    assert_equal 1, status
    _, _, status = lint(dir, "--warnings-ok")
    assert_equal 0, status
  end

  # A file that does not parse is reported with protoc's error, the others
  # are still linted, and the exit status is 2
  def test_directory_with_a_parse_error
    dir = tree(
      "acme/v1/bad.proto" => "syntax = \"proto3\";\npackage acme.v1;\nmessage Bad {\n  string id = \n}\n",
      "acme/v1/user.proto" => CLEAN.sub("string id", "required string id").sub("proto3", "proto2"),
      "acme/v1/ok.proto" => CLEAN.sub("User", "Other")
    )
    out, _, status = lint(dir, "--rules", "minimal", "--format", "json")
    assert_equal 2, status
    rows = out.lines.map { |l| JSON.parse(l) }
    assert_equal [["error", "P0302", "acme/v1/bad.proto"], ["warning", "W0101", "acme/v1/user.proto"]],
      rows.map { |r| [r["severity"], r["code"], r["file"]] }
  end

  def test_rules_and_except
    source = "syntax = \"proto2\";\npackage acme.v1;\nmessage User {\n  required string userId = 1;\n}\n"
    dir = tree("acme/v1/user.proto" => source)
    out, = lint(dir, "--rules", "minimal", "--format", "json")
    assert_equal %w[FIELD_NOT_REQUIRED], rules_in(out)
    out, = lint(dir, "--rules", "minimal,naming", "--format", "json")
    assert_equal %w[FIELD_NOT_REQUIRED FIELD_LOWER_SNAKE_CASE], rules_in(out)
    out, = lint(dir, "--rules", "minimal,naming", "--except", "W0101", "--format", "json")
    assert_equal %w[FIELD_LOWER_SNAKE_CASE], rules_in(out)
    _, err, status = lint(dir, "--rules", "nonsense")
    assert_equal 2, status
    assert_match(/Unknown rule or set: nonsense/, err)
  end

  def test_config_file
    dir = tree(
      ".protostar.yml" => "lint:\n  rules: [minimal, naming]\n  except: [FIELD_NOT_REQUIRED]\n  ignore: [\"vendor/**\"]\n",
      "acme/v1/user.proto" => "syntax = \"proto2\";\npackage acme.v1;\nmessage User {\n  required string userId = 1;\n}\n",
      "vendor/x/thing.proto" => "message thing {}\n"
    )
    out, = lint(dir, "--format", "json")
    assert_equal %w[FIELD_LOWER_SNAKE_CASE], rules_in(out)
    File.write(File.join(dir, ".protostar.yml"), "lint:\n  colour: red\n")
    _, err, status = lint(dir)
    assert_equal 2, status
    assert_match(/unknown lint setting colour/, err)
  end

  def test_comment_directives
    source = <<~PROTO
      syntax = "proto3";
      package acme.v1;
      message User {
        // protostar-lint: disable-next-line FIELD_LOWER_SNAKE_CASE
        string userId = 1;
        string userName = 2;
        // protostar-lint: disable W0204
        string userEmail = 3;
        string userPhone = 4;
        // protostar-lint: enable W0204
        string userAge = 5;
      }
    PROTO
    dir = tree("acme/v1/user.proto" => source)
    out, = lint(dir, "--format", "json")
    assert_equal [6, 11], out.lines.map { |l| JSON.parse(l)["line"] }
    File.write(File.join(dir, ".protostar.yml"), "lint:\n  allow_comment_directives: false\n")
    out, = lint(dir, "--format", "json")
    assert_equal 5, out.lines.size
  end

  def test_compiler_warnings_pass_through_once
    source = "syntax = \"proto3\";\npackage acme.v1;\nimport \"google/protobuf/empty.proto\";\nmessage User {}\n"
    dir = tree("acme/v1/user.proto" => source)
    out, = lint(dir, "--rules", "minimal", "--format", "json")
    assert_equal %w[IMPORT_USED], rules_in(out)
    out, = lint(dir, "--rules", "naming", "--format", "json")
    assert_equal %w[V0703], rules_in(out)
    out, = lint(dir, "--rules", "minimal", "--except", "IMPORT_USED", "--format", "json")
    assert_empty out
  end

  def test_github_format
    dir = tree("acme/v1/user.proto" => CLEAN.sub("string id", "string userId"))
    out, = lint(dir, "--format", "github")
    assert_equal "::warning file=#{dir}/acme/v1/user.proto,line=6,col=10,endLine=6,endColumn=16,title=W0204::" \
      "field `userId` is not lower_snake_case%0Ahelp: name it `user_id`%0Anote: rule FIELD_LOWER_SNAKE_CASE " \
      "(default set)%0Afix: rename `userId` to `user_id`\n", out
  end

  def test_text_format_with_and_without_colour
    dir = tree("acme/v1/user.proto" => CLEAN.sub("string id", "string userId"))
    out, = lint(dir, "--color", "always")
    assert_includes out, "\e[1;33mwarning[W0204]\e[0m"
    out, = lint(dir)
    assert_includes out, <<~TEXT
      6 |   string userId = 1;
        |          ^^^^^^ not lower_snake_case
    TEXT
    assert out.end_with?("1 file: 0 errors, 1 warning (1 fixable with --fix)\n#{Protostar::Lint::Command::EXPLAIN_HINT}\n")
  end

  def test_fix_rewrites_and_diff_does_not
    source = "package acme.v1;\n\nenum Color {\n  RED = 0;\n  Blue = 1;\n}\n\nmessage User {\n  optional Color fooBar = 1;\n}\n"
    dir = tree("acme/v1/user.proto" => source)
    path = File.join(dir, "acme/v1/user.proto")
    out, _, status = lint(dir, "--diff", "--rules", "minimal,naming")
    assert_equal source, File.read(path)
    assert_equal 1, status
    assert_includes out, "+syntax = \"proto2\";\n"
    out, _, status = lint(dir, "--fix", "--rules", "minimal,naming")
    assert_equal <<~PROTO, File.read(path)
      syntax = "proto2";
      package acme.v1;

      enum Color {
        COLOR_UNSPECIFIED = 0;
        COLOR_BLUE = 1;
      }

      message User {
        optional Color foo_bar = 1;
      }
    PROTO
    assert_includes out, "@@ -1,10 +1,11 @@\n+syntax = \"proto2\";\n package acme.v1;\n \n enum Color {\n" \
      "-  RED = 0;\n-  Blue = 1;\n+  COLOR_UNSPECIFIED = 0;\n+  COLOR_BLUE = 1;\n }\n"
    assert out.end_with?("1 file: 0 errors, 0 warnings\n")
    assert_equal 0, status
    out, _, status = lint(dir, "--rules", "minimal,naming")
    assert_equal ["1 file: 0 errors, 0 warnings\n", 0], [out, status]
  end

  def test_fix_leaves_a_name_that_is_used_elsewhere
    source = "syntax = \"proto2\";\npackage acme.v1;\nenum Color {\n  COLOR_UNSPECIFIED = 0;\n  Red = 1;\n}\n" \
      "message User {\n  optional Color c = 1 [default = Red];\n}\n"
    dir = tree("acme/v1/user.proto" => source)
    lint(dir, "--fix", "--rules", "ENUM_VALUE_UPPER_SNAKE_CASE")
    assert_equal source, File.read(File.join(dir, "acme/v1/user.proto"))
  end

  def test_include_paths
    dir = tree("proto/acme/v1/user.proto" => CLEAN, "proto/acme/v1/use.proto" =>
      "syntax = \"proto3\";\npackage acme.v1;\nimport \"acme/v1/user.proto\";\nmessage Use {\n  User u = 1;\n}\n")
    out, _, status = lint("-I", File.join(dir, "proto"), File.join(dir, "proto/acme/v1/use.proto"))
    assert_equal ["1 file: 0 errors, 0 warnings\n", 0], [out, status]
    _, err, status = lint("-I", File.join(dir, "elsewhere"), File.join(dir, "proto/acme/v1/use.proto"))
    assert_equal 2, status
    assert_match(/not under any include path/, err)
  end

  def test_explain_and_list
    out, _, status = lint("--explain", "L0301")
    assert_equal 0, status
    assert out.start_with?("L0301: field number already used\n\n")
    out, = lint("--explain", "w0101")
    assert out.start_with?("W0101: FIELD_NOT_REQUIRED (minimal set, longevity)\n\nA required field")
    _, err, status = lint("--explain", "X9999")
    assert_equal ["No code or rule X9999.\n", 2], [err, status]
    out, = lint("--list-rules")
    assert_equal Protostar::Lint::RULES.size, out.lines.size
  end

  def test_usage_mistakes
    assert_equal 2, lint[2]
    assert_equal 2, lint("--format", "xml", tree("a.proto" => CLEAN))[2]
    assert_equal 2, lint("/nowhere/at/all.proto")[2]
  end

  # The executable dispatches `lint`, and NO_COLOR keeps the output plain
  def test_executable
    dir = tree("acme/v1/user.proto" => CLEAN.sub("string id", "string userId"))
    out, err, status = Open3.capture3({"NO_COLOR" => "1"}, RbConfig.ruby, EXE, "lint", dir)
    assert_equal ["", 1], [err, status.exitstatus]
    assert out.start_with?("warning[W0204]: field `userId` is not lower_snake_case\n")
    refute_includes out, "\e["
  end
end
