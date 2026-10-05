# frozen_string_literal: true

# Views against eager decode: reading one scalar and one nested field, and
# a full to_h, on a large message (about 1.2 MiB: a 512 KiB bytes field,
# 512 strings of 1 KiB, 1000 nested messages) and on the populated
# TestAllTypes of bench/codec_bench.rb (413 bytes).
#
#   bundle exec ruby bench/view_bench.rb
#   ruby --yjit ... for YJIT numbers

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "protostar"
require "benchmark/ips"
%w[corpus golden_hash schema_fixtures codec_fixtures].each do |f|
  require_relative "../test/support/#{f}"
end

set = CodecFixtures.load("google/protobuf/unittest.proto")
klass = set["proto2_unittest.TestAllTypes"]

large = klass.new(
  optional_int32: 1,
  optional_bytes: "y" * (512 * 1024),
  repeated_string: Array.new(512) { "x" * 1024 },
  optional_nested_message: {bb: 42},
  repeated_nested_message: Array.new(1000) { |i| {bb: i} },
  optional_foreign_message: {c: 9}
).encode.freeze

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
  repeated_nested_message: [{bb: 218}, {bb: 318}], repeated_foreign_message: [{c: 219}, {c: 319}],
  optional_nested_enum: :BAZ, repeated_nested_enum: %i[BAR BAZ], oneof_bytes: "604"
)
small = klass.new(fields).encode.freeze

read_two = ->(m) { m.optional_int32 + m.optional_nested_message.bb }
[large, small].each do |bytes|
  raise "views disagree" unless read_two.call(klass.view(bytes)) == read_two.call(klass.decode(bytes))
  raise "views disagree" unless klass.view(bytes).to_h == klass.decode(bytes).to_h
end

def allocations
  GC.start
  before = GC.stat(:total_allocated_objects)
  yield
  GC.stat(:total_allocated_objects) - before
end

puts RUBY_DESCRIPTION
{"large" => large, "small" => small}.each do |label, bytes|
  puts "#{label}: #{bytes.bytesize} bytes; objects allocated reading two fields: " \
    "view #{allocations { read_two.call(klass.view(bytes)) }}, decode #{allocations { read_two.call(klass.decode(bytes)) }}"
end

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  x.report("large: view, two fields") { read_two.call(klass.view(large)) }
  x.report("large: decode, two fields") { read_two.call(klass.decode(large)) }
  x.report("large: view to_h") { klass.view(large).to_h }
  x.report("large: decode to_h") { klass.decode(large).to_h }
end

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  x.report("small: view, two fields") { read_two.call(klass.view(small)) }
  x.report("small: decode, two fields") { read_two.call(klass.decode(small)) }
  x.report("small: view to_h") { klass.view(small).to_h }
  x.report("small: decode to_h") { klass.decode(small).to_h }
  x.report("small: view to_message") { klass.view(small).to_message }
end
