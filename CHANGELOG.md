# Changelog

## Unreleased

- Schema objects are the one representation: `Schema::File.draft` builds them (the
  compiler, the DSL and `File.from_proto` all draft), `to_proto`/`from_proto` translate to
  and from protoc's `FileDescriptorProto`. `Schema::Builder` and the descriptor hashes are
  gone; `to_h` is `to_proto.to_h`, for reading.
- Options are objects with a reader per option (`options.deprecated?`, `options.packed`),
  custom options by extension (`options.extension("acme.limits")`), unknown fields as
  bytes, and `options.features` resolved.
- `Klass.reflection`: read and write a message class's fields by descriptor, name or number.
- `Message#visibility` and `Enum#visibility` answer `:local` and `:export`.

- Project skeleton, vendored protobuf corpus pinned to protoc 36.2, protoc goldens.
