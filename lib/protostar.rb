# frozen_string_literal: true

require_relative "protostar/version"

module Protostar
  class Error < StandardError; end
end

require_relative "protostar/errors"
require_relative "protostar/schema"
require_relative "protostar/wire"
require_relative "protostar/unknown_field"
require_relative "protostar/enum"
require_relative "protostar/message"
require_relative "protostar/codec"
require_relative "protostar/types"
require_relative "protostar/well_known"
require_relative "protostar/json"
require_relative "protostar/text"
require_relative "protostar/compiler"
