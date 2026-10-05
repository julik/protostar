# frozen_string_literal: true

# Evaluates the probes in probes.txt and describes each result as text, the
# same way under google-protobuf 4.36.2 (script/record_differential.rb) and
# under this gem (differential_test.rb).
#
# probes.txt holds Ruby snippets separated by lines of `---`. A snippet's
# `#~ reason` line marks a known difference; the test skips it, saying why.
module Differential
  PROBES = File.join(__dir__, "probes.txt")
  RECORDED = File.join(__dir__, "google-protobuf-4.36.2.txt")

  Probe = Struct.new(:source, :difference)

  def self.probes
    File.read(PROBES).split(/^---\n/).filter_map do |chunk|
      next if chunk.strip.empty?
      difference = chunk[/^#~ (.*)$/, 1]
      Probe.new(chunk.gsub(/^#~ .*\n/, "").strip, difference)
    end
  end

  # @return [String] the result's description, or the error's class and
  #   message (only the class for ParseError, whose wording is upb's own)
  def self.run(source, binding)
    describe(eval(source, binding)) # standard:disable Security/Eval
  rescue Exception => e # standard:disable Lint/RescueException
    case e
    when NameError then "!! #{e.class}: #{e.name}" # Ruby 3.4 reworded these
    else (e.class.name == "Google::Protobuf::ParseError") ? "!! #{e.class}" : "!! #{e.class}: #{e.message[0, 200]}"
    end
  end

  def self.describe(value)
    case value
    when String then "#{value.inspect} #{value.encoding} frozen=#{value.frozen?}"
    when Google::Protobuf::RepeatedField, Google::Protobuf::Map
      "#{value.class.name.split("::").last}(#{value.inspect}) frozen=#{value.frozen?}"
    else canonical(value)
    end
  end

  # inspect, with Hashes, Sets and Encodings spelled the same on every Ruby
  def self.canonical(value)
    case value
    when Hash then "{#{value.map { |k, v| "#{canonical(k)} => #{canonical(v)}" }.sort.join(", ")}}" # upb maps have no order
    when Array then "[#{value.map { |v| canonical(v) }.join(", ")}]"
    when Encoding then value.name
    else
      (defined?(::Set) && value.is_a?(::Set)) ? "Set#{canonical(value.to_a)}" : value.inspect
    end
  end

  # @return [Binding] where probes run, with the test protos loaded
  def self.setup
    require "json"
    require "bigdecimal"
    require "google/protobuf"
    require "google/protobuf/well_known_types"
    require "basic_test_pb"
    require "basic_test_proto2_pb"
    require "generated_code_pb"
    require "repeated_field_test_pb"
    require "service_test_pb"
    TOPLEVEL_BINDING.dup
  end

  # The recorded outputs, one per probe, separated like the probes
  def self.recorded
    File.read(RECORDED).split(/^---\n/).map(&:chomp)
  end
end
