# frozen_string_literal: true

# Makes `require "google/protobuf"` load the google-protobuf shim bundled with protostar
# instead of Google's gem, for grpc and anything else that requires it. Require this
# before anything else touches google/protobuf:
#
#   require "protostar/google_protobuf_shim"
#   require "grpc"
#
# The shim's files are in the gem but not on its load path, so a plain
# `require "protostar"` leaves Google's gem alone.
shim_loaded = defined?(::Google::Protobuf::IMPLEMENTATION) && ::Google::Protobuf::IMPLEMENTATION == :PROTOSTAR
if defined?(::Google::Protobuf::DescriptorPool) && !shim_loaded
  raise LoadError, "Google's google-protobuf is already loaded, so the protostar shim cannot replace it. " \
    "Require protostar/google_protobuf_shim before anything requires google/protobuf"
end

# The shim may be loaded already, from the same files or from the git-sourced gem
unless shim_loaded
  shim_lib = File.expand_path("../../shims/google-protobuf/lib", __dir__)
  # In front of Google's gem, should Bundler have activated it for grpc
  $LOAD_PATH.unshift(shim_lib) unless $LOAD_PATH.include?(shim_lib)
  require "google/protobuf"
end
