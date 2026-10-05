# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "protostar"

require "minitest/autorun"
require "minitest/fail_fast" if ENV["FAIL_FAST"]

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }
