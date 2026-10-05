# protostar

Pure Ruby protocol buffers. A `.proto` compiler, an encoder and decoder, and a drop-in
stand-in for the `google-protobuf` gem so that `grpc` and friends run without `protoc`
or native extensions.

Under construction. The plan lives in `llm/instructions/genesis.md`.

## Replacing google-protobuf

`shims/google-protobuf` is a gem named `google-protobuf` that provides Google's
`Google::Protobuf` API on protostar. Point Bundler at it and every gem that depends
on `google-protobuf` (grpc among them) gets it instead of Google's:

```ruby
gem "protostar", github: "julik/protostar"
gem "google-protobuf", github: "julik/protostar", glob: "shims/google-protobuf/*.gemspec"
```

Its [README](shims/google-protobuf/README.md) has the other ways to install it and
what it covers. `bundle exec rake shim:test` runs its suite with its own bundle.

## Licence

MIT (`LICENSE.txt`). The Google `.proto` files bundled under `lib/protostar/compiler/include/`,
the code generated from them, and the vendored protobuf sources under `test/corpus/` are
Google's, under the BSD 3-Clause licence; [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists them
and carries that licence.
