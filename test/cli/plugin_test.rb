# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "protostar/plugin"

# protoc-gen-protostar with hand-built CodeGeneratorRequests
class PluginTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  EXE = File.join(ROOT, "exe/protoc-gen-protostar")
  PROJECT = File.join(ROOT, "test/fixtures/project")
  Request = Protostar::Plugin::Request
  Response = Protostar::Plugin::Response
  Emitters = Protostar::Compiler::Emitters

  def files
    @files ||= Protostar::Compiler.new(include_paths: [File.join(PROJECT, "proto")])
      .compile(["acme/directory.proto", "acme/editions.proto"], source_info: true)
  end

  def request(parameter, generate = ["acme/directory.proto"])
    Request.new(file_to_generate: generate, parameter: parameter, proto_file: files.map(&:to_proto),
      compiler_version: Protostar::Google::Protobuf::Compiler::Version.new(major: 36, minor: 2))
  end

  def run_plugin(request)
    out, err, status = Open3.capture3(RbConfig.ruby, EXE, stdin_data: request.encode, binmode: true)
    assert_equal ["", 0], [err, status.exitstatus]
    Response.decode(out)
  end

  def test_through_stdin
    response = run_plugin(request("grpc,rbs"))
    assert_equal "", response.error
    assert_equal 3, response.supported_features
    assert_equal 998, response.minimum_edition
    assert_equal 1001, response.maximum_edition
    directory = files.find { |f| f.name == "acme/directory.proto" }
    expected = Emitters::Grpc.new.emit([directory]).merge(Emitters::Rbs.new.emit([directory]))
    assert_equal expected, response.file.to_h { |f| [f.name, f.content] }
  end

  def test_native_ruby_by_default
    response = Response.decode(Protostar::Plugin.respond(request("").encode))
    directory = files.find { |f| f.name == "acme/directory.proto" }
    assert_equal Emitters::Ruby.new.emit([directory]), response.file.to_h { |f| [f.name, f.content] }
  end

  def test_google_format
    response = Response.decode(Protostar::Plugin.respond(request("google").encode))
    directory = files.find { |f| f.name == "acme/directory.proto" }
    assert_equal Emitters::GoogleRuby.new.emit([directory]), response.file.to_h { |f| [f.name, f.content] }
  end

  def test_errors_are_reported_in_the_response
    {
      "fortran" => "unknown output \"fortran\"; use ruby, google, rbs, grpc",
      "ruby,google" => "ruby and google both write *_pb.rb; ask for one of them"
    }.each do |parameter, message|
      response = Response.decode(Protostar::Plugin.respond(request(parameter).encode))
      assert_equal message, response.error
      assert_empty response.file
    end
    response = Response.decode(Protostar::Plugin.respond(request("rbs", ["acme/editions.proto"]).encode))
    assert_equal "acme/editions.proto: #{Protostar::CLI::RBS_EDITIONS}", response.error
  end
end
