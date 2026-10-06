# frozen_string_literal: true

# Runs the test suite with Ruby's warnings on (RUBYOPT=-w) and fails when any
# warning comes from protostar itself: a file under lib/, or code that lib/
# generates and evals ("(protostar decoder ...)", "(protostar encoder ...)").
# Warnings from tests and gems are left alone. Serial, so that each
# warning is printed once.
#
#   ruby script/warnings.rb
require "open3"

ROOT = File.expand_path("..", __dir__)
OURS = %r{\A(?:#{Regexp.escape(File.join(ROOT, "lib"))}/|lib/|\(protostar )[^:]*:\d+: warning: }

env = {"RUBYOPT" => [ENV["RUBYOPT"], "-w"].compact.join(" ")}
found = []
status = Open3.popen2e(env, "bundle", "exec", "rake", "test:serial", chdir: ROOT) do |_stdin, out, wait|
  out.each_line do |line|
    if OURS.match?(line)
      found << line
    elsif !line.include?(": warning: ")
      print line
    end
  end
  wait.value
end

unless found.empty?
  counts = found.tally
  warn "#{found.size} warnings from lib/ (#{counts.size} distinct):"
  counts.sort_by { |_, n| -n }.each { |line, n| warn "  #{n}x #{line}" }
  exit 1
end
abort "the test suite failed under -w" unless status.success?
puts "No warnings from lib/."
