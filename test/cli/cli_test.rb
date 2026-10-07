# frozen_string_literal: true

require "test_helper"
require "open3"
require "protostar/cli"
require "rbconfig"

# `protostar compile`, run as a subprocess over test/fixtures/project
class CliTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  EXE = File.join(ROOT, "exe/protostar")
  PROJECT = File.join(ROOT, "test/fixtures/project")
  Emitters = Protostar::Compiler::Emitters

  # Runs the executable; arguments not starting with a command get `compile`
  def protostar(*args, chdir: PROJECT)
    args = ["compile", *args] unless %w[compile --version --help frobnicate].include?(args.first)
    out, err, status = Open3.capture3(RbConfig.ruby, EXE, *args, chdir: chdir)
    [out, err, status.exitstatus]
  end

  def compiled(*names)
    Protostar::Compiler.new(include_paths: [File.join(PROJECT, "proto")]).compile(names, source_info: true)
  end

  def test_version
    out, err, status = protostar("--version")
    assert_equal "protostar #{Protostar::VERSION}\n", out
    assert_empty err
    assert_equal 0, status
  end

  def test_every_output
    tmpdir do |dir|
      %w[ruby google rbs grpc].each { |k| Dir.mkdir(File.join(dir, k)) }
      set = File.join(dir, "set.binpb")
      out, err, status = protostar("-I", "proto", "--ruby_out=#{dir}/ruby", "--google_out=#{dir}/google",
        "--rbs_out=#{dir}/rbs", "--grpc_out=#{dir}/grpc", "--descriptor_set_out=#{set}",
        "acme/person.proto", "acme/directory.proto")
      assert_equal ["", "", 0], [out, err, status]
      files = compiled("acme/person.proto", "acme/directory.proto")
      named = files.select { |f| f.name.start_with?("acme/") }
      {
        "ruby" => Emitters::Ruby.new, "google" => Emitters::GoogleRuby.new,
        "rbs" => Emitters::Rbs.new, "grpc" => Emitters::Grpc.new
      }.each do |kind, emitter|
        emitter.emit(named).each do |path, content|
          assert_equal content, File.read(File.join(dir, kind, path)), "#{kind}/#{path}"
        end
      end
      assert_equal %w[directory_pb.rb person_pb.rb], Dir.children(File.join(dir, "ruby/acme")).sort
      assert_equal %w[directory_services_pb.rb], Dir.children(File.join(dir, "grpc/acme"))
      assert_equal Emitters::DescriptorSet.new.emit(named), File.binread(set)
    end
  end

  def test_rbs_next_to_ruby_out_describes_protostar_classes
    tmpdir do |dir|
      out, err, status = protostar("-I", "proto", "--ruby_out=#{dir}", "--rbs_out=#{dir}",
        "acme/person.proto", "acme/editions.proto")
      assert_equal ["", "", 0], [out, err, status]
      files = compiled("acme/person.proto", "acme/editions.proto").select { |f| f.name.start_with?("acme/") }
      Emitters::ProtostarRbs.new.emit(files).each do |path, content|
        assert_equal content, File.read(File.join(dir, path)), path
      end
      assert_includes File.read(File.join(dir, "acme/person_pb.rbs")), "< ::Protostar::Message"
    end
  end

  def test_descriptor_set_flags
    tmpdir do |dir|
      set = File.join(dir, "set.binpb")
      _, err, status = protostar("--proto_path=proto", "--descriptor_set_out=#{set}", "--include_imports",
        "--include_source_info", "acme/directory.proto")
      assert_equal ["", 0], [err, status]
      files = Protostar.load_descriptor_set(File.binread(set), pool: Protostar::Schema::Pool.new)
      assert_equal %w[google/protobuf/timestamp.proto acme/person.proto acme/directory.proto], files.map(&:name)
      assert files.last.source_info
    end
  end

  def test_generated_ruby_loads_and_works
    tmpdir do |dir|
      _, err, status = protostar("-Iproto", "--ruby_out=#{dir}", "acme/person.proto")
      assert_equal ["", 0], [err, status]
      script = <<~RUBY
        require "acme/person_pb"
        person = Acme::Person.new(name: "Ada", kind: :HUMAN, born: Protostar::Google::Protobuf::Timestamp.new(seconds: 1))
        copy = Acme::Person.decode(person.encode)
        print copy.name, " ", copy.kind, " ", copy.born.seconds, " ", Acme::Person::Kind::HUMAN
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-I", dir, "-e", script)
      assert_equal ["Ada HUMAN 1 1", "", 0], [out, err, status.exitstatus]
    end
  end

  def test_input_given_as_a_path_on_disk
    tmpdir do |dir|
      _, err, status = protostar("-I./proto", "--ruby_out=#{dir}", "proto/acme/person.proto")
      assert_equal ["", 0], [err, status]
      assert File.file?(File.join(dir, "acme/person_pb.rb"))
    end
  end

  def test_errors_name_the_file_on_disk
    tmpdir do |dir|
      out, err, status = protostar("-I", "broken", "--ruby_out=#{dir}", "bad.proto")
      assert_equal "", out
      assert_equal "broken/bad.proto:5:13: Field number 1 has already been used in \"A\" by field \"x\". " \
        "Next available field number is 2.\n", err
      assert_equal 1, status
      assert_empty Dir.children(dir)
    end
  end

  def test_msvs_error_format
    tmpdir do |dir|
      _, err, status = protostar("-I./broken/", "--error_format=msvs", "--ruby_out=#{dir}", "bad.proto")
      assert_equal "broken/bad.proto(5) : error in column=13: Field number 1 has already been used in \"A\" by " \
        "field \"x\". Next available field number is 2.\n", err
      assert_equal 1, status
    end
  end

  def test_warnings_go_to_stderr_and_succeed
    tmpdir do |dir|
      _, err, status = protostar("-Iproto", "--ruby_out=#{dir}", "acme/unused.proto")
      assert_equal ["proto/acme/unused.proto:5:1: warning: Import acme/person.proto is unused.\n", 0], [err, status]
      _, err, = protostar("-Iproto", "--error_format=msvs", "--ruby_out=#{dir}", "acme/unused.proto")
      assert_equal "proto/acme/unused.proto(5) : warning in column=1: warning: Import acme/person.proto is unused.\n", err
    end
  end

  def test_command_line_mistakes
    {
      ["-Iproto", "acme/person.proto", "acme/directory.proto"] =>
        "2 files cannot share stdout; add --ruby_out=DIR to write a _pb.rb for each.\n",
      ["-Iproto", "--ruby_out=."] => "Missing input file.\n",
      ["-Iproto", "--error_format=xml", "--ruby_out=.", "acme/person.proto"] => "Unknown error format: xml\n",
      ["-Iproto", "--ruby_out=nowhere", "acme/person.proto"] => "nowhere/: No such file or directory\n",
      ["-Iproto", "--ruby_out=.", "acme/nothing.proto"] =>
        "Could not make proto path relative: acme/nothing.proto: No such file or directory\n",
      ["-Iproto", "--ruby_out=.", "broken/bad.proto"] => "broken/bad.proto: #{Protostar::CLI::NO_MAPPING}\n"
    }.each do |args, message|
      out, err, status = protostar("compile", *args)
      assert_equal ["", message, 1], [out, err, status], args.join(" ")
    end
  end

  def test_generator_errors
    tmpdir do |dir|
      _, err, status = protostar("compile", "-Iproto", "--rbs_out=#{dir}", "acme/editions.proto")
      assert_equal ["acme/editions.proto: #{Protostar::CLI::RBS_EDITIONS}--rbs_out: \n", 1], [err, status]
      _, err, status = protostar("compile", "-Ibroken", "--google_out=#{dir}", "bad_package.proto")
      assert_equal "--google_out: bad_package.proto: Invalid character in ruby_package option: character ';' is " \
        "not allowed because it could enable code injection.\n", err
      assert_equal 1, status
      assert_empty Dir.children(dir)
    end
  end

  def test_unknown_command_and_help
    _, err, status = protostar("frobnicate")
    assert_includes err, "Unknown command: frobnicate"
    assert_equal 1, status
    out, _, status = protostar("--help")
    assert_includes out, "--descriptor_set_out=FILE"
    assert_equal 0, status
  end
end
