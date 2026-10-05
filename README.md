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
