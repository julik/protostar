# frozen_string_literal: true

# Extracts the inline test cases of protoc's parser_unittest.cc into
# test/corpus/parser_cases/cases.json, so the compiler's tests can replay them
# without protoc or the google-protobuf gem.
#
#   bundle exec ruby script/extract_parser_cases.rb   # needs BUNDLE_WITH=oracle and protoc
#
# Every call to ExpectParsesTo, ExpectHasErrors, ExpectHasEarlyExitErrors,
# ExpectHasValidationErrors and ExpectHasWarnings whose arguments are string
# literals (adjacent literals, raw strings and `#define`d string macros
# included) becomes a case. The expected text-format FileDescriptorProto of
# ExpectParsesTo is converted to protoc's JSON with `protoc --encode` and the
# google-protobuf gem. Calls with computed arguments are listed under
# "skipped" with the reason.

require "json"
require "open3"

ROOT = File.expand_path("..", __dir__)
SOURCE = File.join(ROOT, "test/corpus/protobuf/src/google/protobuf/compiler/parser_unittest.cc")
OUTPUT = File.join(ROOT, "test/corpus/parser_cases/cases.json")
PROTOC = ENV.fetch("PROTOC", File.expand_path("~/.cache/protostar/protoc-36.2/bin/protoc"))
EXPECTATIONS = %w[ExpectParsesTo ExpectHasErrors ExpectHasEarlyExitErrors ExpectHasValidationErrors
  ExpectHasWarnings].freeze

# A tiny reader over the C++ source: string literals, identifiers, punctuation
class CppReader
  ESCAPES = {"n" => "\n", "t" => "\t", "r" => "\r", "\"" => "\"", "'" => "'", "\\" => "\\", "?" => "?",
             "a" => "\a", "b" => "\b", "f" => "\f", "v" => "\v"}.freeze

  attr_reader :pos

  def initialize(src, pos = 0)
    @src = src
    @pos = pos
  end

  def skip_space
    loop do
      if @src[@pos]&.match?(/\s/)
        @pos += 1
      elsif @src[@pos, 2] == "//"
        @pos = @src.index("\n", @pos) || @src.size
      elsif @src[@pos, 2] == "/*"
        @pos = @src.index("*/", @pos) + 2
      elsif @src[@pos] == "#" && (@pos == 0 || @src[@pos - 1] == "\n")
        @pos = @src.index("\n", @pos) || @src.size
      else
        break
      end
    end
  end

  def peek
    skip_space
    @src[@pos]
  end

  # Reads one argument: a run of adjacent literals and macro names, or
  # HasSubstr(...) around one. Returns [kind, value] or [:unsupported, text]
  def argument(macros)
    skip_space
    start = @pos
    if @src[@pos..].start_with?("HasSubstr(", "testing::HasSubstr(")
      @pos = @src.index("(", @pos) + 1
      kind, value = argument(macros)
      skip_space
      return [:unsupported, @src[start...@pos]] unless kind == :string && @src[@pos] == ")"
      @pos += 1
      return [:substring, value]
    end
    out = +""
    any = false
    loop do
      skip_space
      if @src[@pos] == "\""
        out << normal_literal
        any = true
      elsif @src[@pos, 2] == "R\""
        out << raw_literal
        any = true
      elsif (m = @src[@pos..].match(/\A([A-Z_][A-Z0-9_]*)\b/)) && macros.key?(m[1])
        out << macros[m[1]]
        @pos += m[1].size
        any = true
      else
        break
      end
    end
    skip_space
    if any && [",", ")"].include?(@src[@pos])
      [:string, out]
    else
      @pos = start
      [:unsupported, nil]
    end
  end

  # Skips to the end of the current call's argument list
  def skip_to_close
    depth = 0
    while @pos < @src.size
      c = @src[@pos]
      if c == "\""
        normal_literal
        next
      elsif @src[@pos, 2] == "R\""
        raw_literal
        next
      elsif c == "("
        depth += 1
      elsif c == ")"
        return @pos += 1 if depth == 0
        depth -= 1
      end
      @pos += 1
    end
  end

  def normal_literal
    @pos += 1
    out = +""
    loop do
      c = @src[@pos]
      @pos += 1
      break if c == "\""
      if c == "\\"
        e = @src[@pos]
        @pos += 1
        if ESCAPES.key?(e)
          out << ESCAPES[e]
        elsif e.match?(/[0-7]/)
          digits = e
          while digits.size < 3 && @src[@pos]&.match?(/[0-7]/)
            digits << @src[@pos]
            @pos += 1
          end
          out << digits.to_i(8).chr
        elsif e == "x"
          digits = +""
          while @src[@pos]&.match?(/\h/)
            digits << @src[@pos]
            @pos += 1
          end
          out << digits.to_i(16).chr
        else
          raise "unknown escape \\#{e} at #{@pos}"
        end
      else
        out << c
      end
    end
    out
  end

  def raw_literal
    @pos += 2
    paren = @src.index("(", @pos)
    delimiter = @src[@pos...paren]
    close = @src.index(")#{delimiter}\"", paren)
    out = @src[(paren + 1)...close]
    @pos = close + delimiter.size + 2
    out
  end
end

def each_test(src)
  src.scan(/^TEST_F\((\w+),\s*(\w+)\)\s*\{/) do
    match = Regexp.last_match
    start = match.end(0)
    depth = 1
    pos = start
    while depth > 0
      c = src[pos]
      if c == "\""
        r = CppReader.new(src, pos)
        r.normal_literal
        pos = r.pos
        next
      elsif src[pos, 2] == "R\"" && src[pos - 1] !~ /\w/
        r = CppReader.new(src, pos)
        r.raw_literal
        pos = r.pos
        next
      elsif src[pos, 2] == "//"
        pos = src.index("\n", pos)
        next
      elsif c == "'"
        pos = src.index("'", pos + ((src[pos + 1] == "\\") ? 3 : 2)) + 1
        next
      end
      depth += 1 if c == "{"
      depth -= 1 if c == "}"
      pos += 1
    end
    yield match[1], match[2], start, pos
  end
end

def macros_at(src, offset)
  macros = {}
  src[0...offset].each_line do |line|
    if (m = line.match(/^#define\s+([A-Z_][A-Z0-9_]*)\s+(".*")\s*$/))
      macros[m[1]] = CppReader.new(m[2]).normal_literal
    elsif (m = line.match(/^#undef\s+([A-Z_][A-Z0-9_]*)/))
      macros.delete(m[1])
    end
  end
  macros
end

def encode_expected(text)
  require "google/protobuf"
  require "google/protobuf/descriptor_pb"
  includes = File.join(ROOT, "test/corpus/protobuf/src")
  out, err, status = Open3.capture3(PROTOC, "-I#{includes}", "--encode=google.protobuf.FileDescriptorProto",
    "google/protobuf/descriptor.proto", stdin_data: text, binmode: true)
  return [nil, err.strip] unless status.success?
  proto = Google::Protobuf::FileDescriptorProto.decode(out)
  [JSON.parse(Google::Protobuf::FileDescriptorProto.encode_json(proto)), nil]
end

src = File.read(SOURCE)
cases = []
skipped = []
each_test(src) do |fixture, name, from, to|
  body = src[from...to]
  assignments = body.to_enum(:scan, /require_syntax_identifier_\s*=\s*(true|false)/).map do
    [Regexp.last_match.begin(0), Regexp.last_match[1] == "true"]
  end
  index = 0
  previous_call = nil
  body.to_enum(:scan, /\b(#{EXPECTATIONS.join("|")})\(/o).map { Regexp.last_match }.each do |call|
    kind = call[1]
    macros = macros_at(src, from + call.begin(0))
    reader = CppReader.new(body, call.end(0))
    input_kind, input = reader.argument(macros)
    id = "#{fixture}.#{name}" + ((index > 0) ? "##{index}" : "")
    index += 1
    if input_kind != :string || reader.peek != ","
      skipped << {id: id, kind: kind, reason: "input is not a string literal"}
      next
    end
    reader.instance_variable_set(:@pos, reader.pos + 1)
    reader.skip_space
    expected_kind, expected = reader.argument(macros_at(src, from + reader.pos))
    unless %i[string substring].include?(expected_kind) && reader.peek == ")"
      skipped << {id: id, kind: kind, reason: "expectation is not a string literal"}
      next
    end
    require_syntax = assignments.reverse.find { |at, _| at < call.begin(0) }&.last || false
    # errors accumulate over a test's calls unless the test clears them
    fresh = previous_call.nil? || body[previous_call...call.begin(0)].include?("error_collector_.text_.clear()")
    previous_call = call.begin(0)
    entry = {id: id, test: "#{fixture}.#{name}", fresh: fresh, kind: kind, input: input, require_syntax: require_syntax}
    # the test builds files into its pool first; the Ruby test must do the same
    entry[:setup] = true if body[0...call.begin(0)].include?("BuildFile(")
    if kind == "ExpectParsesTo"
      json, error = encode_expected(expected)
      if json.nil?
        skipped << {id: id, kind: kind, reason: "protoc --encode failed: #{error}"}
        next
      end
      entry[:expected] = json
    else
      entry[:expected] = expected
      entry[:substring] = expected_kind == :substring
    end
    cases << entry
  end
end

# SourceInfoTest: the marked-up input and, per HasSpan call, the descriptor
# path the C++ accessor chain denotes, the markers bounding the span and the
# expected comments. Paths are computed from descriptor.proto's field numbers.

DESCRIPTOR_FIELDS = begin
  golden = JSON.parse(File.read(File.join(ROOT, "test/corpus/goldens/google/protobuf/descriptor.proto.json")))
  file = golden["file"].find { |f| f["name"] == "google/protobuf/descriptor.proto" }
  types = {}
  walk = lambda do |message, scope|
    full = "#{scope}.#{message["name"]}"
    types[full] = message.fetch("field", []).to_h { |f| [f["name"], [f["number"], f["typeName"]&.delete_prefix(".")]] }
    message.fetch("nestedType", []).each { |n| walk.call(n, full) }
  end
  file["messageType"].each { |m| walk.call(m, file["package"]) }
  types
end

# Splits a call's argument list at top-level commas
def call_arguments(text, open)
  depth = 0
  pos = open
  start = open + 1
  args = []
  while pos < text.size
    c = text[pos]
    if c == "\""
      r = CppReader.new(text, pos)
      r.normal_literal
      pos = r.pos
      next
    elsif c == "'"
      pos += (text[pos + 1] == "\\") ? 4 : 3
      next
    elsif c == "("
      depth += 1
    elsif c == ")"
      depth -= 1
      if depth == 0
        args << text[start...pos].strip
        return [args, pos + 1]
      end
    elsif c == "," && depth == 1
      args << text[start...pos].strip
      start = pos + 1
    end
    pos += 1
  end
  raise "unbalanced call"
end

# A C++ accessor chain such as `file_.message_type(0).field(1)` as [path, type]
def accessor_path(expr, bindings)
  m = expr.match(/\A(\w+)((?:\.\w+\(\d*\))*)\z/) or raise "unsupported expression #{expr}"
  path, type = (m[1] == "file_") ? [[], "google.protobuf.FileDescriptorProto"] : bindings.fetch(m[1])
  m[2].scan(/\.(\w+)\((\d*)\)/) do |name, index|
    number, next_type = DESCRIPTOR_FIELDS.fetch(type).fetch(name)
    path += [number]
    path += [Integer(index)] unless index.empty?
    type = next_type
  end
  [path, type]
end

def string_or_nil(arg)
  return nil if arg == "nullptr"
  kind, value = CppReader.new(arg + ")").argument({})
  raise "unsupported comment argument #{arg}" unless kind == :string
  value
end

source_info = []
src.scan(/^TEST_F\(SourceInfoTest,\s*(\w+)\)\s*\{/) do
  name = Regexp.last_match[1]
  from = Regexp.last_match.end(0)
  to = src.index(/^\}/, from)
  body = src[from...to]
  begin
    parse_at = body.index("Parse(") or raise "no Parse call"
    kind, input = CppReader.new(body, parse_at + "Parse(".size).argument({})
    raise "Parse input is not a literal" unless kind == :string
    bindings = {}
    body.scan(/const\s+[\w:]+&\s+(\w+)\s*=\s*([^;]+);/m) do |var, expr|
      bindings[var] = accessor_path(expr.gsub(/\s+/, ""), bindings)
    end
    spans = []
    body.to_enum(:scan, /\b(HasSpan|HasSpanWithComment)\(/).map { Regexp.last_match }.each do |call|
      args, = call_arguments(body, call.end(0) - 1)
      markers = args.first.start_with?("'") ? args.shift(2).map { |a| a[1...-1].delete("\\") } : [nil, nil]
      path, type = accessor_path(args.shift.gsub(/\s+/, ""), bindings)
      comments = nil
      if call[1] == "HasSpanWithComment"
        comments = args.shift(3).map { |a| string_or_nil(a) }
      else
        if (field = args.shift)
          kind, field_name = CppReader.new(field + ")").argument({})
          raise "unsupported field argument #{field}" unless kind == :string
          path += [DESCRIPTOR_FIELDS.fetch(type).fetch(field_name).first]
        end
        index = args.shift
        path += [Integer(index)] if index && index != "-1"
        comments = args.shift(3).map { |a| string_or_nil(a) } unless args.empty?
      end
      span = {path: path, start: markers[0], end: markers[1]}
      span[:comments] = comments if comments
      spans << span
    end
    source_info << {id: "SourceInfoTest.#{name}", input: input, spans: spans}
  rescue => e
    skipped << {id: "SourceInfoTest.#{name}", kind: "SourceInfoTest", reason: e.message}
  end
end

File.write(OUTPUT, JSON.pretty_generate({
  source: "test/corpus/protobuf/src/google/protobuf/compiler/parser_unittest.cc",
  generated_by: "script/extract_parser_cases.rb",
  cases: cases,
  source_info: source_info,
  skipped: skipped
}) + "\n")
puts "#{cases.size} cases, #{source_info.size} source info cases, #{skipped.size} skipped"
skipped.each { |s| puts "  skipped #{s[:id]} (#{s[:kind]}): #{s[:reason]}" }
