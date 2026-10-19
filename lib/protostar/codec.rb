# frozen_string_literal: true

module Protostar
  # Binary encoding and decoding of Message objects. Use the methods on
  # message classes and instances; these modules are their implementation.
  module Codec
    # Needed while a class is defined, never after
    autoload :DecodeGenerator, ::File.expand_path("codec/decode_generator", __dir__)
    autoload :EncodeGenerator, ::File.expand_path("codec/encode_generator", __dir__)
  end
end

require_relative "codec/decoder"
require_relative "codec/sizer"
require_relative "codec/encoder"
