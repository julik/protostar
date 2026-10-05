# frozen_string_literal: true

# The gem loads its C extension from here; with protostar there is only one
# implementation, so this loads google/protobuf and nothing else.
require "google/protobuf"
