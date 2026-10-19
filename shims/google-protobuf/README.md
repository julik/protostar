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

The shim ships inside the protostar gem, off its load path. Require it before anything
requires `google/protobuf`, and Google's gem, even if installed, is never loaded:

```ruby
require "protostar/google_protobuf_shim"
require "grpc"
Google::Protobuf::IMPLEMENTATION # => :PROTOSTAR
```

That needs no Gemfile changes, but Google's gem stays installed when something (grpc)
depends on it. To replace it in the bundle, install the shim as a gem named
`google-protobuf`. rubygems.org's `google-protobuf` is Google's, so this one does not come
from there. There are three routes. Each ends with every `require "google/protobuf"` in the
process loading this gem.

### 1. With Bundler, from git

Name both gems from the protostar repository. The `glob:` tells Bundler where the
shim's gemspec is:

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

Pin a `ref:` or `tag:` for reproducible builds. Any gem in the bundle that depends on
`google-protobuf` (`grpc` wants `>= 3.25, < 5.0`, `googleapis-common-protos-types`
`~> 4.26`) now resolves to this one, because 4.36.2.1 satisfies them.

The same works from a path (a vendored or sibling checkout) and from a gem server you
control:

```ruby
gem "protostar", path: "vendor/protostar"
gem "google-protobuf", path: "vendor/protostar/shims/google-protobuf"
```

```ruby
source "https://gems.example.com" do # where you pushed both gems
  gem "protostar"
  gem "google-protobuf"
end
```

A scoped `source` block keeps Bundler from taking Google's gem of the same name from
rubygems.org. Build the gems with `gem build protostar.gemspec` at the root and
`gem build google-protobuf.gemspec` in `shims/google-protobuf`; they must be the same
release, since the shim depends on its protostar version exactly.

### 2. When a gem wants google-protobuf 3

Some gems pin `google-protobuf` below 4: `googleapis-common-protos-types` before 1.15
asks for `~> 3.18`, `grpc` 1.50 for `~> 3.21`. Bundler then refuses this gem. With the
shim from `path:` and `googleapis-common-protos-types` 1.14.0, `bundle lock` says:

```
Because google-protobuf >= 3.18, < 4.A could not be found in source at
`vendor/protostar/shims/google-protobuf`
and googleapis-common-protos-types >= 1.8.0, < 1.15.0 depends on
google-protobuf ~> 3.18,
  googleapis-common-protos-types >= 1.8.0, < 1.15.0 cannot be used.
So, because Gemfile depends on googleapis-common-protos-types = 1.14.0,
  version solving has failed.
```

Bundler 4.1 adds an `override` keyword that rewrites a requirement before resolving,
including requirements other gems place on it:

```ruby
gem "protostar", path: "vendor/protostar"
gem "google-protobuf", path: "vendor/protostar/shims/google-protobuf"
gem "googleapis-common-protos-types", "1.14.0"

override "google-protobuf", version: ">= 3.18"
```

As of 4.1.0.beta1 it has a bug: `bundle install` in frozen or deployment mode
(`BUNDLE_FROZEN`, `BUNDLE_DEPLOYMENT`) refuses a Gemfile that overrides a transitive
dependency, even when the lockfile already satisfies the override
([rubygems#9907](https://github.com/ruby/rubygems/issues/9907)). `google-protobuf` is one
here, through `googleapis-common-protos-types`: with BUNDLE_FROZEN set, 4.1.0.beta1
refused the Gemfile above right after a plain `bundle install` had written a lockfile
that satisfies it. Until that is fixed, use the plugin below with Bundler 4.0 for
deployments.

On Bundler 4.0 and earlier, the
[bundler-override](https://rubygems.org/gems/bundler-override) plugin does the same, per
depending gem:

```ruby
plugin "bundler-override"
require File.join(Bundler::Plugin.index.load_paths("bundler-override")[0], "bundler-override") rescue nil

gem "protostar", github: "julik/protostar"
gem "google-protobuf", github: "julik/protostar", glob: "shims/google-protobuf/*.gemspec"
gem "googleapis-common-protos-types", "1.14.0"

if Bundler::Plugin.installed?("bundler-override")
  override "googleapis-common-protos-types", requirements: {"google-protobuf" => ">= 3.18"}
end
```

The plugin is installed by the first `bundle install` (not by `bundle lock`). It replaces
the Gemfile's `override` method with its own, so drop it before you use Bundler 4.1's.

Either way this only fixes resolution. A gem old enough to want google-protobuf 3 may
ship `_pb.rb` files written by protoc before 3.21, which call
`DescriptorPool#build`; the shim raises `NotImplementedError` for those
(`googleapis-common-protos-types` 1.4 does, 1.14 does not). There is nothing to do but
upgrade that gem.

### 3. Without Bundler

Install both gems (built as above) with `gem install`. When Google's `google-protobuf` is
installed too, RubyGems activates the highest version, and 4.36.2.1 beats Google's 4.36.2,
but not a later Google release. Ask for this one before anything requires
`google/protobuf`:

```ruby
gem "google-protobuf", "= 4.36.2.1"
require "google/protobuf"
Google::Protobuf::IMPLEMENTATION # => :PROTOSTAR
```

`gem` has to run first: once Google's gem is activated (by a `require` or by another gem
asking for it), asking for this one raises `Gem::LoadError`.

### Check which one you got

```ruby
require "google/protobuf"
Google::Protobuf::IMPLEMENTATION # => :PROTOSTAR (Google's gem says :NATIVE or :FFI)
```

With Bundler, `bundle lock` shows it too: the lockfile lists `google-protobuf (4.36.2.1)`
under the GIT, PATH or private source, and no `google-protobuf` under rubygems.org.

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
(`test/differential/`).

## Known differences

[test/known_differences.md](test/known_differences.md) has the full list, with the
probe for each. In short:

- Not there: `DescriptorPool#build`, the DSL of `_pb.rb` files from protoc before 3.21
  (regenerate those files), and `Google::Protobuf::Internal::ObjectCache`.
- Descriptors inspect as the FFI implementation's do (`Google::Protobuf::FieldDescriptor: name`),
  not with an address; their names are frozen UTF-8 Strings.
- Accessors are methods on the class, not `method_missing`, and protostar's own message
  methods (`encode`, `to_text`, `merge!`, ...) are there too: message classes subclass
  `Google::Protobuf::AbstractMessage`, as in the gem, and it subclasses `Protostar::Message`.
- Lookups take Strings and Symbols alike; `each` without a block returns an Enumerator.
- Maps iterate and encode in insertion order (upb uses its hash order).
- JSON: error messages are protostar's (the class is the gem's `ParseError`); extensions
  are read and written for the top-level message only; an empty `Any` writes `{}` and
  `{}` reads as an empty `Any`, where the C gem raises.
- Two of Google's tests are omitted by Google's own conditions (a missing
  `TestExtensions` in proto3, and a check guarded on `IMPLEMENTATION == :NATIVE`, which
  passes in this gem's own tests); `gc_test`, `memory_test`, `stress` and
  `object_cache_test` test the C implementation and are not ported.

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

## Licence

MIT (`LICENSE.txt`). The generated `_pb.rb` files and the Google tests under `test/google/`
come from Google's Protocol Buffers, under the BSD 3-Clause licence; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
