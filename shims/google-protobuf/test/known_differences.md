# Known differences

## Google's tests (`test/google/`)

Every ported test passes. Two are omitted by conditions in Google's own files:

- `basic.rb` `test_dup_extensions`: omitted upstream too, the proto3 module has no `TestExtensions` (it runs and passes in `basic_proto2.rb`).
- `service_test.rb` `test_service_options_extensions`: omitted unless `IMPLEMENTATION == :NATIVE`; the same check passes in `test/shim/messages_test.rb`.

Not ported, as implementation-specific: `gc_test.rb`, `memory_test.rb`, `stress.rb`, `object_cache_test.rb` (there is no `Google::Protobuf::Internal::ObjectCache`), `implementation.rb` (expects `:NATIVE` or `:FFI`; here it is `:PROTOSTAR`) and `ruby_version.rb` (Google's CI). There is no `oom_test.rb` in the pinned corpus.

## Against google-protobuf 4.36.2

`test/differential/probes.txt` marks each probe whose result differs from the C gem's with `#~` and the reason. In short:

- Descriptors inspect as the FFI implementation's do (`Google::Protobuf::FieldDescriptor: name`), not with an address. Descriptor names are frozen UTF-8 Strings.
- Accessors are methods on the class, not `method_missing`; protostar's own message methods (`encode`, `to_text`, `merge!`, ...) are there too.
- Lookups take Strings and Symbols alike. `each` without a block returns an Enumerator.
- Maps iterate and encode in insertion order (upb uses its hash order).
- Error messages from JSON parsing are protostar's (the class, `ParseError`, is the same).
- JSON writes and reads extensions of the top-level message only.
- An empty `Any` encodes to `{}` and `{}` decodes to an empty `Any`, as the conformance suite requires; the C gem raises `ParseError` on encode.
