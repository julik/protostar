# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"

# The playbooks under examples/ run, print what their READMEs say they print,
# and show their files exactly as they are on disk.
#
# A README fence whose first line is `# examples/<playbook>/<file>` (or `//`
# for a .proto) is a slice of that file; the slices of one file, joined by a
# blank line, are the whole file. A `console` fence is a terminal: `$ ` lines
# are commands and the lines under each are what it prints.
class ExamplesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXAMPLES = File.join(ROOT, "examples")
  PLAYBOOKS = %w[
    01_compile_a_proto
    02_read_a_message
    03_compose_and_send_over_http
    04_json_for_debugging
  ].freeze
  MARKER = %r{\A(?:#|//) (examples/[^\s]+)\n}
  # Files a reader never needs to see in full
  UNSHOWN = /(_pb\.rb|\.binpb|README\.md|Gemfile\.lock)\z/
  # Commands the playbooks show that only make sense on the reader's machine
  SKIPPED = ["bundle install"].freeze
  HTTP = "03_compose_and_send_over_http"

  Fence = Struct.new(:info, :body)
  Command = Struct.new(:line, :output)

  def test_the_index_lists_every_playbook_in_order
    index = File.read(File.join(EXAMPLES, "README.md"))
    positions = PLAYBOOKS.map { |dir| index.index("(#{dir}/)") }
    assert positions.all?, "examples/README.md must link every playbook: #{PLAYBOOKS.zip(positions).to_h}"
    assert_equal positions.sort, positions
    assert_equal PLAYBOOKS, Dir.children(EXAMPLES).select { |c| File.directory?(File.join(EXAMPLES, c)) }.sort
  end

  def test_fences_are_the_files_byte_for_byte
    PLAYBOOKS.each do |dir|
      slices = Hash.new { |h, k| h[k] = [] }
      fences(dir).each do |fence|
        next if fence.info == "console"
        marked = MARKER.match(fence.body)
        assert marked, "examples/#{dir}/README.md has a #{fence.info} fence without a file marker:\n#{fence.body}"
        slices[marked[1]] << fence.body.delete_prefix(marked[0])
      end
      slices.each do |path, parts|
        assert_equal File.read(File.join(ROOT, path)), parts.join("\n"), "#{path} differs from its README fences"
      end
      shown = Dir.glob("**/*", base: File.join(EXAMPLES, dir)).reject { |f| File.directory?(File.join(EXAMPLES, dir, f)) }
        .grep_v(UNSHOWN).map { |f| "examples/#{dir}/#{f}" }
      assert_equal shown.sort, slices.keys.grep_v(/_pb\.rb\z/).sort, "examples/#{dir}/README.md must show every file"
    end
  end

  def test_generated_code_is_current
    out, status = Open3.capture2e(RbConfig.ruby, File.join(ROOT, "script", "examples.rb"), "check")
    assert status.success?, out
  end

  def test_every_command_in_the_readmes_prints_what_they_promise
    PLAYBOOKS.each do |dir|
      commands(dir).each do |command|
        next if SKIPPED.include?(command.line)
        next if dir == HTTP && command.line.start_with?("ruby ") # test_the_http_server_and_client_talk
        actual =
          case command.line
          when /\Aruby (\S+)\z/ then ruby(dir, $1)
          when /\Abundle exec protostar (.+)\z/ then in_copy_without_generated_code(dir) { |tmp| protostar(tmp, $1.split) }
          when "bundle exec rake protos" then in_copy_without_generated_code(dir) { |tmp| rake_protos(tmp) }
          else flunk "examples/#{dir}/README.md shows `#{command.line}`, which this test does not know how to run"
          end
        assert_output_matches command, actual, dir
      end
    end
  end

  def test_the_view_is_faster_than_decoding
    out = ruby("02_read_a_message", "view.rb")
    decode, view = out.scan(/(\d+\.\d+) ms/).flatten.map(&:to_f)
    assert_operator view, :<, decode, out
  end

  def test_the_sender_wrote_the_committed_bytes
    in_copy_without_generated_code("02_read_a_message", keep: true) do |tmp|
      FileUtils.rm(Dir.glob(File.join(tmp, "*.binpb")))
      run_ok(RbConfig.ruby, "-I", File.join(ROOT, "lib"), "sender/write.rb", chdir: tmp)
      %w[order.binpb orders.binpb].each do |name|
        assert_equal File.binread(File.join(EXAMPLES, "02_read_a_message", name)), File.binread(File.join(tmp, name)), name
      end
    end
  end

  def test_the_http_server_and_client_talk
    dir = HTTP
    server_command, client_command = commands(dir).select { |c| c.line.start_with?("ruby ") }
    assert_equal ["ruby server.rb", "ruby client.rb"], [server_command&.line, client_command&.line]
    port = free_port
    env = bundler_env.merge("PORT" => port.to_s)
    out, writer = IO.pipe
    pid = Process.spawn(env, RbConfig.ruby, "-I", File.join(ROOT, "lib"), "server.rb",
      chdir: File.join(EXAMPLES, dir), out: writer, err: writer)
    writer.close
    begin
      first = Timeout.timeout(30) { out.gets }
      assert_equal "Listening on http://127.0.0.1:#{port}\n", first
      assert_output_matches client_command, ruby(dir, "client.rb", env: {"PORT" => port.to_s}), dir
    ensure
      Process.kill("INT", pid)
      Process.wait(pid)
    end
    rest = Timeout.timeout(10) { out.read }
    assert_output_matches server_command, (first + rest).gsub(":#{port}", ":9292"), dir
  end

  private

  def fences(dir)
    readme = File.read(File.join(EXAMPLES, dir, "README.md"))
    readme.scan(/^```(\w*)\n(.*?)^```$/m).map { |info, body| Fence.new(info, body) }
  end

  def commands(dir)
    fences(dir).select { |f| f.info == "console" }.flat_map do |fence|
      fence.body.split(/^\$ /).reject(&:empty?).map do |chunk|
        line, output = chunk.split("\n", 2)
        Command.new(line, output.to_s)
      end
    end
  end

  def assert_output_matches(command, actual, dir)
    assert_equal normalize(command.output), normalize(actual), "`#{command.line}` in examples/#{dir}"
  end

  # Timings differ from run to run, and Hash#inspect changed in Ruby 3.4
  def normalize(text)
    text = text.gsub(/\d+\.\d+ ms/, "N ms")
    return text if RUBY_VERSION >= "3.4"
    text.gsub(/:(\w+)=>/, '\1: ').gsub(/("(?:[^"\\]|\\.)*")=>/, '\1 => ')
  end

  def bundler_env
    {"BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile")}
  end

  def ruby(dir, script, env: {})
    run_ok(RbConfig.ruby, "-I", File.join(ROOT, "lib"), script, chdir: File.join(EXAMPLES, dir), env: env)
  end

  def protostar(dir, args)
    run_ok(RbConfig.ruby, File.join(ROOT, "exe", "protostar"), *args, chdir: dir)
  end

  # The Rakefile shells out to `protostar`, so one goes first on the PATH
  def rake_protos(dir)
    bin = File.join(dir, ".bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "protostar"), "#!#{RbConfig.ruby}\nload #{File.join(ROOT, "exe", "protostar").inspect}\n")
    File.chmod(0o755, File.join(bin, "protostar"))
    path = [bin, ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR)
    run_ok(RbConfig.ruby, "-e", 'require "rake"; Rake.application.run(%w[protos])', chdir: dir, env: {"PATH" => path})
  end

  def run_ok(*cmd, chdir:, env: {})
    out, status = Open3.capture2e(bundler_env.merge(env), *cmd, chdir: chdir)
    assert status.success?, "#{cmd.join(" ")} failed in #{chdir}:\n#{out}"
    out
  end

  # Runs the block in a copy of the playbook with its _pb.rb files removed,
  # then checks that what the block generated is what is committed
  def in_copy_without_generated_code(dir, keep: false)
    Dir.mktmpdir do |tmp|
      FileUtils.cp_r(File.join(EXAMPLES, dir, "."), tmp)
      generated = Dir.glob("**/*_pb.rb", base: tmp)
      generated.each { |rel| FileUtils.rm(File.join(tmp, rel)) } unless keep
      out = yield tmp
      unless keep
        written = generated.select { |rel| File.exist?(File.join(tmp, rel)) }
        refute_empty written
        written.each do |rel|
          assert_equal File.read(File.join(EXAMPLES, dir, rel)), File.read(File.join(tmp, rel)), "#{dir}/#{rel}"
        end
      end
      out
    end
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end
end
