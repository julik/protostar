# frozen_string_literal: true

require "test_helper"
require "json"
require "ripper"
require_relative "../compiler/validation_cases"

# Every message the compiler can report has a code in
# Protostar::Diagnostics::Codes: the message strings in the compiler's source
# are read with Ripper and each must match a template, so a new message
# without a code fails here. Every recorded protoc error case is also
# compiled and rendered, which must not raise.
class DiagnosticsCodesTest < Minitest::Test
  Codes = Protostar::Diagnostics::Codes
  COMPILER = File.join(TestSupport::ROOT, "lib/protostar/compiler")
  # Where the compiler's messages are written. TextFormat's own messages only
  # reach a diagnostic inside "Error while parsing option value for ...", and
  # the emitters raise Emitters::Error, which is not a diagnostic.
  SOURCES = %w[lexer.rb parser.rb linker.rb option_interpreter.rb symbol_table.rb validator.rb run.rb].freeze
  # The methods a message is passed to
  REPORTERS = %w[error warning record_error record_error_at record_warning_at add_error import_error import_warning
    report name_error value_error consume consume_end_of_declaration].freeze
  # Strings that are parts of a message, appended to or embedded in one
  # matched as a whole elsewhere
  FRAGMENTS = [
    "Next available field number is \u0001", "There are no available field numbers", "It is explicitly marked 'local'",
    "It defaulted to local from file-level 'option features.default_symbol_visibility = '\u0001';",
    " (features.enforce_naming_style = STYLE_LEGACY can be used to opt out of this check)",
    " (features.enforce_naming_style = STYLE2024 can be used to opt out of this check)",
    " (features.enforce_proto_limits = LEGACY_NO_EXPLICIT_LIMITS can be used to opt out of this check)",
    " Maybe you meant \".\u0001\"?", " The next available enum value is \u0001.",
    "should not begin with \u0001 if a field named \u0001 exists. This can cause collisions in generated code.",
    "should not end with _value if a field named \u0001 exists. This can cause collisions in generated code.",
    "should not be named descriptor. This can cause collisions in generated code."
  ].freeze

  # [file, line, sample] for every string literal that reads like a message:
  # an argument to a reporting method, or a sentence starting with a capital
  # letter or a quote; interpolations become "\u0001"
  def self.messages
    SOURCES.flat_map do |file|
      out = []
      walk(Ripper.sexp(File.read(File.join(COMPILER, file))), out, file, false)
      out
    end.uniq { |_, _, s| s }
  end

  def self.walk(node, out, file, reported)
    return unless node.is_a?(Array)
    if %i[string_literal string_concat].include?(node[0])
      sample, line = sample(node)
      if sample&.include?(" ") && (reported || (sample.size >= 10 && sample.match?(/\A[A-Z"'\u0001\[ ]/)))
        out << [file, line, sample]
      end
      return
    end
    # the labels of related spans are not messages
    return if node[0] == :assoc_new && node[1][0] == :@label && node[1][1] == "related:"
    if %i[method_add_arg command command_call].include?(node[0])
      name = call_name(node)
      if REPORTERS.include?(name)
        node.each { |child| walk(child, out, file, true) }
        return
      end
    end
    node.each { |child| walk(child, out, file, reported) }
  end

  def self.call_name(node)
    target = (node[0] == :method_add_arg) ? node[1] : node
    case target[0]
    when :fcall, :command then target[1][1]
    when :call, :command_call then target[3].is_a?(Array) ? target[3][1] : nil
    end
  end

  def self.sample(node)
    case node[0]
    when :string_literal
      line = nil
      text = node[1][1..].map do |part|
        case part[0]
        when :@tstring_content
          line ||= part[2][0]
          part[1].gsub(/\\(.)/) { $1 }
        when :string_embexpr then "\u0001"
        else ""
        end
      end.join
      [text, line]
    when :string_concat
      a, line = sample(node[1])
      b, = sample(node[2])
      [a && b && a + b, line]
    end
  end

  def test_every_compiler_message_has_a_code
    messages = self.class.messages
    assert_operator messages.size, :>, 200
    missing = messages.reject do |_, _, sample|
      FRAGMENTS.include?(sample) || Codes.lookup(sample.tr("\u0001", "X"))
    end
    assert_empty missing.map { |file, line, sample| "#{file}:#{line}: #{sample.inspect}" }, "messages without a code"
  end

  # A template is reachable when it matches a message in the source, or the
  # message, its interpolations as wildcards, matches the template. The pool's
  # clash errors are reported as diagnostics too.
  def test_every_template_is_reachable
    pool = []
    self.class.walk(Ripper.sexp(File.read(File.join(TestSupport::ROOT, "lib/protostar/schema/pool.rb"))), pool, "pool.rb", true)
    texts = (self.class.messages + pool).map { |_, _, s| s.tr("\u0001", "X") }
    samples = (self.class.messages + pool).map do |_, _, s|
      Regexp.new("\\A#{s.split("\u0001", -1).map { |part| Regexp.escape(part) }.join(".*")}\\z", Regexp::MULTILINE)
    end
    unused = Codes::ENTRIES.flat_map { |e| e.templates.map { |t| [e.code, t] } }.reject do |_, template|
      text = template.gsub(/%\{\w+\}/, "X")
      pattern = Codes.pattern(template)
      samples.any? { |s| s.match?(text) } || texts.any? { |t| pattern.match?(t) }
    end
    assert_empty unused, "templates no compiler message matches; a message changed or went away"
  end

  def test_codes_are_unique_and_explained
    codes = Codes::ENTRIES.map(&:code)
    assert_equal codes.uniq, codes
    codes.each { |c| assert_match(/\A[PLV]\d{4}\z/, c) }
    Codes::ENTRIES.each do |entry|
      refute_empty entry.summary
      assert_operator entry.explanation.size, :>, 40, entry.code
    end
  end

  def test_lookup_prefers_the_most_specific_template
    assert_equal "P0301", Codes.lookup("Expected \"required\", \"optional\", or \"repeated\".").code
    assert_equal "P0001", Codes.lookup("Expected \";\".").code
    assert_equal "L0508", Codes.lookup("Enum type \"E\" has no value named \"X\" for option \"o\".").code
    assert_equal "L0402", Codes.lookup("Enum type \"E\" has no value named \"X\".").code
    assert_nil Codes.lookup("Something nobody says.")
  end

  def render_all(diagnostics, sources)
    renderer = Protostar::Diagnostics::Renderer.new(source: ->(d) { sources[d.file] })
    diagnostics.each do |d|
      text = renderer.render(d)
      assert d.code, "no code for #{d.message.inspect}"
      assert text.start_with?("#{d.error? ? "error" : "warning"}[#{d.code}]: "), text
      source = sources[d.file] && Protostar::Diagnostics::Source.new(sources[d.file])
      Protostar::Diagnostics::Formats.json(d, source: source)
      Protostar::Diagnostics::Formats.github(d, source: source)
    end
  end

  def test_every_validation_case_renders
    count = 0
    ValidationCases::CASES.each_value do |c|
      compiler = Protostar::Compiler.new
      begin
        compiler.compile([c[:files].keys.first], sources: c[:files])
        diagnostics = compiler.diagnostics
      rescue Protostar::Compiler::Error => e
        diagnostics = e.diagnostics
      end
      count += diagnostics.size
      render_all(diagnostics, c[:files])
    end
    assert_operator count, :>, 100
  end

  def test_every_parser_case_renders
    data = JSON.parse(File.read(File.join(TestSupport::CORPUS, "parser_cases/cases.json")))
    count = 0
    data["cases"].each do |c|
      next if c["kind"] == "ExpectParsesTo"
      sources = {"foo.proto" => c["input"]}
      parser = Protostar::Compiler::Parser.new(c["input"], require_syntax: c["require_syntax"])
      parser.parse
      diagnostics = (parser.errors + parser.warnings).map do |line, column, message|
        Protostar::Compiler::Diagnostic.new("foo.proto", line + 1, column + 1, message)
      end
      if parser.errors.empty?
        begin
          compiler = Protostar::Compiler.new(bundled_includes: false)
          compiler.compile(["foo.proto"], sources: sources, protoc_cli: false)
          diagnostics += compiler.diagnostics
        rescue Protostar::Compiler::Error => e
          diagnostics += e.diagnostics
        end
      end
      count += diagnostics.size
      render_all(diagnostics, sources)
    end
    assert_operator count, :>, 100
  end
end
