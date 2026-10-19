# frozen_string_literal: true

require "test_helper"

# sig/ and rbi/protostar.rbi are what script/types.rb makes of the inline RBS
# in lib/ (rake types:generate), and the gem ships them
class SignaturesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_committed_signatures_are_what_lib_generates
    begin
      require_relative "../../script/types"
    rescue LoadError => e
      skip "#{e.message} (the bundle has rbs-inline)"
    end
    assert_empty TypesGen.differences, "run `rake types:generate`"
  end

  def test_the_gem_ships_the_signatures
    spec = Gem::Specification.load(File.join(ROOT, "protostar.gemspec"))
    assert_includes spec.files, "rbi/protostar.rbi"
    assert_includes spec.files, "rbi/protostar/google/protobuf/timestamp_pb.rbi"
    assert_includes spec.files, "sig/protostar/message.rbs"
    assert_includes spec.files, "sig/protostar_manual.rbs"
  end
end
