# google-protobuf, on protostar

A gem named `google-protobuf` that provides Google's `Google::Protobuf` Ruby API
with [protostar](../../README.md) underneath: no C extension, no FFI, no `protoc`.
`grpc`, `googleapis-common-protos-types` and anything else that depends on
`google-protobuf` get this gem instead of Google's, and the `_pb.rb` files
protoc generates load unchanged.

```ruby
require "google/protobuf"
Google::Protobuf::IMPLEMENTATION # => :PROTOSTAR
```

Its version, `4.36.2.1`, says which upstream API it mirrors (4.36.2) and
satisfies the usual requirements (`>= 3.25, < 5.0` for grpc, `~> 4.26` for
googleapis-common-protos-types).

## Installation

rubygems.org's `google-protobuf` is Google's, so Bundler has to be told where
this one lives. Pick one of three routes; each makes every `google-protobuf`
dependency in the bundle resolve to this gem.

### 1. From GitHub

```ruby
gem "protostar", github: "julik/protostar"
gem "google-protobuf", github: "julik/protostar", glob: "shims/google-protobuf/*.gemspec"
```

or, for both from one checkout:

```ruby
git "https://github.com/julik/protostar.git", glob: "{,shims/*/}*.gemspec" do
  gem "protostar"
  gem "google-protobuf"
end
```

Pin a `ref:` or `tag:` for reproducible builds.

### 2. From a path

With protostar vendored or checked out next to the app:

```ruby
gem "protostar", path: "vendor/protostar"
gem "google-protobuf", path: "vendor/protostar/shims/google-protobuf"
```

### 3. From a private gem source

Build the gem and push it, with protostar's, to a gem server you control
(Gemfury, GitHub Packages, a gemstash):

```sh
cd shims/google-protobuf && gem build google-protobuf.gemspec
```

```ruby
source "https://gems.example.com" do
  gem "protostar"
  gem "google-protobuf"
end
```

A scoped `source` block keeps Bundler from taking Google's gem of the same
name from rubygems.org.

Check with `bundle lock`: the lockfile lists `google-protobuf (4.36.2.1)` under
the GIT, PATH or private source, and no `google-protobuf` under rubygems.org.

## What it covers

Everything google-protobuf 4.36 offers Ruby code:

- `DescriptorPool` (`generated_pool`, `new`, `add_serialized_file`, `lookup`),
  `Descriptor`, `FieldDescriptor` (with `get`/`set`/`has?`/`clear`, extensions
  included), `OneofDescriptor`, `EnumDescriptor`, `ServiceDescriptor`,
  `MethodDescriptor`, `FileDescriptor`, their `options` and `to_proto`.
- Message classes: accessors, `has_`, `clear_`, oneof readers, `_const`,
  `_as_value`, `[]`, `[]=`, `to_h`, `inspect`, `==`, `hash`, `dup`, `freeze`,
  `encode`/`decode` with `recursion_limit`, `encode_json`/`decode_json` with the
  gem's options, `MessageExts` and `MessageExts::ClassMethods` for libraries
  that extend every message.
- `RepeatedField` and `Map`, checked on every write, writing through to the
  message they came from.
- The well-known types and their helpers (`Any#pack`, `Timestamp#to_time`,
  `Struct#to_h`, ...), `google/protobuf/well_known_types`, `descriptor_pb`.
- The gem's errors: `RangeError` for integers out of range,
  `Google::Protobuf::TypeError` for wrong types, `ParseError` for bad bytes and
  JSON, `FrozenError`; every enum is open, as in the gem.

Google's own Ruby test suite runs against it (`test/google/`), along with a
gRPC server and client in one process, Bundler resolution, the calls pbbuilder
makes, and 576 probes compared with what google-protobuf 4.36.2 returned
(`test/differential/`). The differences are listed in
[test/known_differences.md](test/known_differences.md).

Not there: the `generated_pool.build` DSL of protoc before 3.21 (regenerate
those files), `Google::Protobuf::Internal::ObjectCache`.

## Two pools

Protostar's own classes (written by `protostar compile --ruby_out`, or with
`Protostar::DSL`) live in `Protostar.generated_pool`. The classes this gem makes
live in `Google::Protobuf::DescriptorPool.generated_pool`, which has its own
schema pool and type registry. The two never share classes:
`Google::Protobuf::Timestamp` here and `Protostar::Google::Protobuf::Timestamp`
there are different classes over the same bytes. Use one style per `.proto`
file; loading the same file both ways gives two sets of classes.

## Development

```sh
bundle install
bundle exec rake test             # the whole suite
bundle exec rake generate         # regenerate the well-known types and fixtures with protostar
bundle exec rake generate:check   # fail when they are out of date
```

`script/record_differential.rb` re-records `test/differential/` under Google's
gem; run it outside the bundle, with `google-protobuf` 4.36.2 installed.
