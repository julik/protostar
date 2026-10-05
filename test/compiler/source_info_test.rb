# frozen_string_literal: true

require "test_helper"

# Tier B: source code info (paths, spans, comments) for every corpus file and
# its imports equals what protoc wrote with --include_source_info. The
# expected value comes from the .binpb golden decoded by the google-protobuf
# gem, so these run only with PROTOSTAR_ORACLE=1.
class CompilerSourceInfoTest < Minitest::Test
  def setup
    skip "needs PROTOSTAR_ORACLE=1 and the oracle bundle" unless Oracle.available?
  end

  CompilerSupport.goldens.each do |rel|
    define_method(:"test_#{rel.tr("/.", "__")}") do
      expected = Oracle.file_hashes(Corpus.golden(rel, :binpb), source_info: true)
      files = CompilerSupport.compiler.compile([rel], source_info: true)
      assert_equal expected.map { |h| h[:name] }, files.map(&:name)
      expected.zip(files) do |hash, file|
        got = file.to_h[:source_code_info][:location]
        want = hash[:source_code_info][:location]
        assert_equal want.size, got.size, "#{file.name}: number of locations"
        want.zip(got).each_with_index do |(w, g), i|
          assert_equal w, g, "#{file.name}: location #{i}"
        end
      end
    end
  end
end
