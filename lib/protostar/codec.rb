# frozen_string_literal: true

module Protostar
  # Binary encoding and decoding of {Message} objects. Use the methods on
  # message classes and instances; these modules are their implementation.
  module Codec
  end
end

require_relative "codec/decoder"
require_relative "codec/decode_generator"
require_relative "codec/sizer"
require_relative "codec/encoder"
require_relative "codec/encode_generator"
