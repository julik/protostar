# frozen_string_literal: true

# Decode and encode of a fully populated proto2_unittest.TestAllTypes, the
# shape of protobuf's TestUtil::SetAllFields: every singular field set and
# two elements in every repeated field.
#
#   bundle exec ruby bench/codec_bench.rb
#   BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1 bundle exec ruby bench/codec_bench.rb  # adds google-protobuf
#   ruby --yjit ... for YJIT numbers

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "protostar"
require "benchmark/ips"
%w[corpus golden_hash schema_fixtures codec_fixtures oracle].each do |f|
  require_relative "../test/support/#{f}"
end

set = CodecFixtures.load("google/protobuf/unittest.proto")
klass = set["proto2_unittest.TestAllTypes"]

sample = {
  int32: [101, 201, 301], int64: [102, 202, 302], uint32: [103, 203, 303], uint64: [104, 204, 304],
  sint32: [105, 205, 305], sint64: [106, 206, 306], fixed32: [107, 207, 307], fixed64: [108, 208, 308],
  sfixed32: [109, 209, 309], sfixed64: [110, 210, 310], float: [111.0, 211.0, 311.0],
  double: [112.0, 212.0, 312.0], bool: [true, true, false], string: %w[115 215 315], bytes: %w[116 216 316]
}
fields = {}
sample.each do |type, (one, two, three)|
  fields[:"optional_#{type}"] = one
  fields[:"repeated_#{type}"] = [two, three]
end
fields.merge!(
  optionalgroup: {a: 117}, repeatedgroup: [{a: 217}, {a: 317}],
  optional_nested_message: {bb: 118}, optional_foreign_message: {c: 119},
  optional_import_message: {d: 120}, optional_public_import_message: {e: 126},
  optional_lazy_message: {bb: 127}, optional_unverified_lazy_message: {bb: 128},
  repeated_nested_message: [{bb: 218}, {bb: 318}], repeated_foreign_message: [{c: 219}, {c: 319}],
  repeated_import_message: [{d: 220}, {d: 320}], repeated_lazy_message: [{bb: 227}, {bb: 327}],
  optional_nested_enum: :BAZ, optional_foreign_enum: :FOREIGN_BAZ, optional_import_enum: :IMPORT_BAZ,
  repeated_nested_enum: %i[BAR BAZ], repeated_foreign_enum: %i[FOREIGN_BAR FOREIGN_BAZ],
  repeated_import_enum: %i[IMPORT_BAR IMPORT_BAZ],
  optional_string_piece: "124", optional_cord: "125", repeated_string_piece: %w[224 324],
  repeated_cord: %w[225 325], oneof_bytes: "604"
)
message = klass.new(fields)
bytes = message.encode
raise "round trip failed" unless klass.decode(bytes) == message

oracle = nil
if Oracle.available?
  pool = Google::Protobuf::DescriptorPool.new
  Google::Protobuf::FileDescriptorSet.decode(File.binread(Corpus.golden("google/protobuf/unittest.proto", :binpb))).file.each do |f|
    pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(f))
  end
  oracle = pool.lookup("proto2_unittest.TestAllTypes").msgclass
end

puts "#{RUBY_DESCRIPTION}"
puts "TestAllTypes: #{bytes.bytesize} bytes"
Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  x.report("protostar decode") { klass.decode(bytes) }
  x.report("protostar decode frozen") { klass.decode(bytes, frozen: true) }
  x.report("protostar encode") { message.encode }
  if oracle
    oracle_message = oracle.decode(bytes)
    x.report("google-protobuf decode") { oracle.decode(bytes) }
    x.report("google-protobuf encode") { oracle.encode(oracle_message) }
  end
end
