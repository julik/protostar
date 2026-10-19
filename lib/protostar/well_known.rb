# frozen_string_literal: true

module Protostar
  # Ruby helpers for the well-known types, with the names google-protobuf's
  # `well_known_types.rb` gives them. Types.define includes the matching
  # mixin into a class whose full name is in MIXINS, so the helpers are
  # there however the class came to be defined.
  #
  # ```ruby
  # any = Google::Protobuf::Any.pack(person)
  # any.unpack(Person)              # => person
  # Google::Protobuf::Timestamp.from_time(Time.now).to_time
  # Google::Protobuf::Struct.from_hash("a" => [1, nil]).to_h
  # ```
  module WellKnown
    # Raised by Struct, Value and ListValue for a Ruby value they cannot hold
    class UnexpectedStructType < Protostar::Error; end
  end
end

require_relative "well_known/any"
require_relative "well_known/timestamp"
require_relative "well_known/duration"
require_relative "well_known/struct"
require_relative "well_known/value"
require_relative "well_known/list_value"

module Protostar
  module WellKnown
    # Full name to the mixin Types.define includes into that class
    MIXINS = {
      "google.protobuf.Any" => Any,
      "google.protobuf.Timestamp" => Timestamp,
      "google.protobuf.Duration" => Duration,
      "google.protobuf.Struct" => Struct,
      "google.protobuf.Value" => Value,
      "google.protobuf.ListValue" => ListValue
    }.freeze
  end
end
