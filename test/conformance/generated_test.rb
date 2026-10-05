# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# conformance/generated is what `protostar compile` writes today
class ConformanceGeneratedTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_generated_classes_are_current
    out, err, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "script", "conformance.rb"), "check")
    assert status.success?, "#{out}#{err}"
  end

  def test_every_message_type_the_runner_sends_is_generated
    files = Dir.glob("**/*_pb.rb", base: File.join(ROOT, "conformance", "generated")).sort
    assert_equal %w[
      conformance/conformance_pb.rb
      conformance/test_protos/test_messages_edition2023_pb.rb
      conformance/test_protos/test_messages_edition_unstable_pb.rb
      editions/golden/test_messages_proto2_editions_pb.rb
      editions/golden/test_messages_proto3_editions_pb.rb
      google/protobuf/test_messages_proto2_pb.rb
      google/protobuf/test_messages_proto3_pb.rb
    ], files
  end
end
