# frozen_string_literal: true

require_relative "protostar/version"

module Protostar
  class Error < StandardError; end
end

require_relative "protostar/schema"
require_relative "protostar/compiler"
