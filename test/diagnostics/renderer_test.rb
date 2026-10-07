# frozen_string_literal: true

require "test_helper"

# The rustc-style rendering of compiler diagnostics, pinned as plain text
class DiagnosticsRendererTest < Minitest::Test
  Diagnostic = Protostar::Compiler::Diagnostic
  Span = Protostar::Diagnostics::Span

  def diagnostics(sources)
    Protostar::Compiler.new.compile([sources.keys.first], sources: sources)
    flunk "expected errors"
  rescue Protostar::Compiler::Error => e
    e.diagnostics
  end

  def render(diagnostic, sources, color: false)
    renderer = Protostar::Diagnostics::Renderer.new(color: color, source: ->(d) { sources[d.file] })
    renderer.render(diagnostic)
  end

  def test_two_labelled_spans_on_two_lines
    sources = {"link.proto" => "syntax = \"proto3\";\npackage p;\nmessage A {\n  int32 m = 1;\n  int32 dup = 1;\n}\n"}
    assert_equal <<~TEXT, render(diagnostics(sources).first, sources)
      error[L0301]: field number 1 is already used in `p.A`
       --> link.proto:5:15
        |
      4 |   int32 m = 1;
        |             - first used by `m`
      5 |   int32 dup = 1;
        |               ^ reused here
        |
        = help: the next available field number is 2
    TEXT
  end

  def test_two_labelled_spans_on_one_line
    sources = {"a.proto" => "syntax = \"proto3\";\nmessage M { int32 x = 1; string x = 2; }\n"}
    assert_equal <<~TEXT, render(diagnostics(sources).first, sources)
      error[L0201]: `x` is defined more than once
       --> a.proto:2:33
        |
      2 | message M { int32 x = 1; string x = 2; }
        |                   -             ^ redefined here
        |                   |
        |                   first defined here
    TEXT
  end

  def test_span_covers_the_whole_type_name
    sources = {"a.proto" => "syntax = \"proto3\";\nmessage M {\n  foo.bar.Baz b = 1;\n}\n"}
    assert_equal <<~TEXT, render(diagnostics(sources).first, sources)
      error[L0203]: `foo.bar.Baz` is not defined
       --> a.proto:3:3
        |
      3 |   foo.bar.Baz b = 1;
        |   ^^^^^^^^^^^ not found in this scope
    TEXT
  end

  # protoc counts a tab as reaching the next multiple of 8; the source is
  # shown with tabs expanded the same way, so the caret lines up
  def test_tabs_in_the_source_line
    sources = {"a.proto" => "syntax = \"proto3\";\nmessage A {\n\tint32 a = 1;\n\tint32\tb = 1;\n}\n"}
    d = diagnostics(sources).first
    assert_equal [4, 21], [d.line, d.column]
    assert_equal <<~TEXT, render(d, sources)
      error[L0301]: field number 1 is already used in `A`
       --> a.proto:4:21
        |
      3 |         int32 a = 1;
        |                   - first used by `a`
      4 |         int32   b = 1;
        |                     ^ reused here
        |
        = help: the next available field number is 2
    TEXT
  end

  def test_parse_error_underlines_the_token
    sources = {"bad.proto" => "syntax = \"proto3\";\nmessage A {\n  string b = 2\n  int32 c = 3;\n}\n"}
    assert_equal <<~TEXT, render(diagnostics(sources).first, sources)
      error[P0001]: expected `;`
       --> bad.proto:4:3
        |
      4 |   int32 c = 3;
        |   ^^^^^ expected `;` here
    TEXT
  end

  def test_error_at_end_of_file
    sources = {"bad.proto" => "syntax = \"proto3\";\nmessage A {}\nenum\n"}
    assert_equal <<~TEXT, render(diagnostics(sources).first, sources)
      error[P0001]: expected enum name
       --> bad.proto:4:1
        |
      4 |
        | ^ expected enum name here
    TEXT
  end

  def test_multi_line_span_starting_at_the_line_start
    source = "syntax = \"proto3\";\nmessage A {\n  int32 a = 1;\n  int32 b = 2;\n}\n"
    d = Diagnostic.new("a.proto", 2, 1, "made up", :warning, code: "W9999", title: "a span over lines",
      spans: [Span.new(2, 1, 5, 2, label: "this whole message")], help: ["first line", "second line"])
    assert_equal <<~TEXT, render(d, {"a.proto" => source})
      warning[W9999]: a span over lines
       --> a.proto:2:1
        |
      2 | / message A {
      3 | |   int32 a = 1;
      4 | |   int32 b = 2;
      5 | | }
        | |_^ this whole message
        |
        = help: first line
        = help: second line
    TEXT
  end

  def test_multi_line_span_starting_mid_line_and_elided
    lines = ["syntax = \"proto3\";", "message A { int32 x = 1;"] + Array.new(6) { |i| "  int32 f#{i} = #{i + 2};" } + ["}"]
    d = Diagnostic.new("a.proto", 2, 13, "made up", :error, code: "W9999", title: "elided",
      spans: [Span.new(2, 13, 9, 2, label: "here"), Span.new(1, 1, 1, 7, label: "syntax", primary: false)])
    assert_equal <<~TEXT, render(d, {"a.proto" => lines.join("\n") + "\n"})
      error[W9999]: elided
       --> a.proto:2:13
        |
      1 |   syntax = "proto3";
        |   ------ syntax
      2 |   message A { int32 x = 1;
        |  _____________^
      3 | |   int32 f0 = 2;
      4 | |   int32 f1 = 3;
      5 | |   int32 f2 = 4;
      ...
      9 | | }
        | |_^ here
    TEXT
  end

  def test_without_a_position
    d = Diagnostic.new("a.proto", nil, nil, "File not found.")
    assert_equal <<~TEXT, render(d, {})
      error[L0101]: File not found.
       --> a.proto
        = help: check the include paths (-I) and the spelling of the name
    TEXT
  end

  def test_without_the_source
    sources = {"a.proto" => "syntax = \"proto3\";\nmessage M {\n  B b = 1;\n}\n"}
    assert_equal <<~TEXT, render(diagnostics(sources).first, {})
      error[L0203]: `B` is not defined
       --> a.proto:3:3
    TEXT
  end

  def test_colour
    sources = {"a.proto" => "syntax = \"proto3\";\nmessage M {\n  B b = 1;\n}\n"}
    text = render(diagnostics(sources).first, sources, color: true)
    assert_includes text, "\e[1;31merror[L0203]\e[0m"
    assert_includes text, "\e[1;31m^\e[0m"
    assert_equal render(diagnostics(sources).first, sources), text.gsub(/\e\[[\d;]*m/, "")
  end

  def test_json_and_github_formats
    sources = {"link.proto" => "syntax = \"proto3\";\npackage p;\nmessage A {\n  int32 m = 1;\n  int32 dup = 1;\n}\n"}
    d = diagnostics(sources).first
    source = Protostar::Diagnostics::Source.new(sources["link.proto"])
    record = Protostar::Diagnostics::Formats.record(d, source: source)
    assert_equal({
      code: "L0301", severity: "error", message: "field number 1 is already used in `p.A`",
      protoc: "Field number 1 has already been used in \"p.A\" by field \"m\". Next available field number is 2.",
      file: "link.proto", path: nil, line: 5, column: 15,
      spans: [
        {line: 5, column: 15, end_line: 5, end_column: 16, label: "reused here", primary: true},
        {line: 4, column: 13, end_line: 4, end_column: 14, label: "first used by `m`", primary: false}
      ],
      help: ["the next available field number is 2"], notes: [], fix: nil, rule: nil
    }, record)
    assert_equal ::JSON.generate(record), Protostar::Diagnostics::Formats.json(d, source: source)
    assert_equal "::error file=link.proto,line=5,col=15,endLine=5,endColumn=16,title=L0301::field number 1 is " \
      "already used in `p.A`%0Ahelp: the next available field number is 2",
      Protostar::Diagnostics::Formats.github(d, source: source)
  end

  def test_protoc_format_is_unchanged
    sources = {"link.proto" => "syntax = \"proto3\";\npackage p;\nmessage A {\n  int32 m = 1;\n  int32 dup = 1;\n}\n"}
    d = diagnostics(sources).first
    assert_equal "link.proto:5:15: Field number 1 has already been used in \"p.A\" by field \"m\". Next available " \
      "field number is 2.", d.to_s
    assert_equal 2, d.spans.size
  end

  def test_source_edits
    text = "a\tbc = 1;\r\nnext é line\n"
    source = Protostar::Diagnostics::Source.new(text)
    edits = [Protostar::Diagnostics::Edit.new(1, 9, 1, 11, "xyz"), Protostar::Diagnostics::Edit.new(2, 9, 2, 13, "LINE")]
    assert_equal "a\txyz = 1;\r\nnext é LINE\n", source.apply(text, edits)
    assert_equal 9, source.display_column(1, 9)
    assert_equal 9, source.display_column(2, 10)
  end
end
