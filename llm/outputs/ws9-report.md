# WS9 report: pbbuilder on protostar, and the streaming builder

## What was built

| File | Contents |
|---|---|
| `script/pbbuilder_suite.rb` | clones cheddar-me/pbbuilder at `3a071d5c6556c79eacd62d8f0501b122ac180bc7` (main, 2025-06-19, v0.20.0) into `tmp/pbbuilder`, writes one Gemfile per Rails version under `tmp/pbbuilder-suite/`, runs pbbuilder's test files unchanged. `shim`: google-protobuf from `shims/google-protobuf` (asserts `IMPLEMENTATION == :PROTOSTAR`). `builder`: a clone in `tmp/pbbuilder-protostar` with the patch applied (asserts google-protobuf is not in the bundle) |
| `Rakefile` | `rake shim:pbbuilder` (shim), `rake builder:pbbuilder` (fresh fork from the patch) |
| `.github/workflows/ci.yml` | two steps at the end of the `shim` job, one per task |
| `lib/protostar/builder.rb` | `Protostar::Builder`, `Builder::Error`, `Protostar::Message.build` |
| `lib/protostar/builder/generator.rb` | makes the per-message builder class |
| `test/builder/` | 9 test files and `builder_support.rb` (a test schema compiled into its own registry, a 3-method cache store) |
| `llm/outputs/ws9-pbbuilder.patch` | pbbuilder on `Protostar::Builder`, against the pinned commit (8 files, +151 −232) |
| `script/pbbuilder_bench.rb` | the three-way measurement |

### API

```ruby
Protostar::Builder.build(Klass, **opts) { |pb| ... }        # => String (binary)
Protostar::Builder.message(Klass, **opts) { |pb| ... }      # => Klass instance (decodes the bytes)
Protostar::Builder.write(io, Klass, **opts) { |pb| ... }    # => io, streamed through a 64 KiB buffer
pb = Protostar::Builder.new(Klass, target = nil, **opts)    # target: nil, a String to append to, or an IO
pb.target!                                                  # flush packed runs; the String, or the flushed IO
Klass.build(fields = nil, **more) { |pb| ... }              # => Klass instance; `new` without a block
# opts: cache_store: nil, overwrites: false, repeated: :append (or :replace)
```

`Klass` may also be a `Schema::Message` (looked up in `Types.registry`) or anything with `msgclass`.
The DSL: one method per field name (`pb.name "x"`, `pb.address { ... }`, `pb.address(obj) { |a| ... }`,
`pb.friends(coll) { |e| ... }`, `pb.attrs(hash)`), plus `set!(name, value = NONE, *attributes, &block)`,
`extract!(obj, *names)` (method calls, or Hash keys as Symbols or Strings), `merge!(hash)`,
`cache!(key, **opts) { }`, `cache_if!(cond, key, **opts) { }`, `encoded!(name, bytes_or_list)` (already encoded
messages), `message_class` (the message being written, which follows nesting). Field methods and `set!` return
the builder.

### How it works

- `Builder.for(Klass)` makes a frozen subclass of `Builder` with one method per distinct field name of `Klass` and of
  every message reachable from it (message fields and map values). The builder writes nested messages with the same
  object, so it needs every name. Each method is a literal `case @k` over the indexes of the classes that have that
  field, calling `__set` (block or no value) or `__put` (a value). It is compiled from source, so it runs in any
  Ractor. Names that are methods of `Builder` or `Object` (public or private: `hash`, `format`, `test`, `select`,
  ...) get no method and are reached with `set!`. The class is kept on the message class in `@__builder` (main
  Ractor only); other Ractors make their own each time.
- State: the current `Wire::Writer` and its String, the class index `@k`, a bitmask of singular fields written in the
  current message, the pending packed runs, a path stack for errors, and spare child writers.
- Each scalar is checked and written at once: tag bytes from `FieldInfo#tag`, varints inline when they fit in a byte.
  Implicit-presence fields skip their zero value on the first write, as `encode` does.
- A nested message (block, Hash, `to_h` object, Timestamp, Duration, wrapper) runs in a child writer taken from a spare
  list. When the block ends, the parent writes the tag, the length and the bytes, and the child goes back to the list.
  Groups need no length and are written in place between their tags. Map entries use a child writer per entry.
- Packed repeated scalars are converted on the call (enum names to numbers, sint zigzag, bools to 0/1, float32
  rounding) and collected per field. When the message ends they are written as one run per field, in field number
  order. Nothing else is held back.
- `cache!` with a store: `store.fetch(key)` or `store.fetch(key, options)`. On a miss the block runs into a child
  writer in the same message, its packed runs are flushed into that fragment, and the frozen bytes are stored. Hit or
  miss, the bytes are appended. On a hit the fragment's top-level tags are scanned, so its singular fields count as
  written. A value that is not a String raises.
- Field blocks are only ever `yield`ed to (the generated methods forward `&block`), so a nested block costs no Proc.
  Per element of a collection with a nested message the builder allocates nothing. On the 1,000-item benchmark below
  without Rails: 1,020 objects for the builder against 16,018 for `new` + `encode`, 4.6 ms against 7.4 ms.

### Overwrites by repetition (the note's option)

`overwrites: false` (default): a second write of a singular field, a second member of a oneof, or a second block for
a singular message field raises `Builder::Error` ("is already set; pass overwrites: true ..."). The output then never
repeats a singular field, so readers that rely on WS11's `overwrites: false` promise read it correctly.
`overwrites: true`: the later write is emitted too, zero values included, and wins when read. A nested message
written again is merged by the reader, and a oneof's last member wins. The class docs say the output then relies on
merge semantics. `Message.build` passes `overwrites: true`, because its bytes are decoded at once and never leave the
process. Map keys are not tracked: a repeated key is ordinary map-entry repetition, last wins.

`repeated: :replace`: an Array (or a single value) assigned to a repeated field replaces earlier assignments in the
same message. Those lists are held as references until the message ends. Elements built with a block still stream.
The pbbuilder fork uses this to get pbbuilder's assignment semantics.

## Tests

`test/builder/`: **177 runs** (70 tests + 107 property runs), 9,892 assertions.

| File | Runs | Covers |
|---|---|---|
| `dsl_test.rb` | 24 | every DSL form compared byte for byte with `Klass.new(...).encode`: scalars of each kind, zero skipping, -0.0, nested blocks, block given a value, collection blocks (Array, Range, nested two deep), arrays of messages/Hashes/Structs, packed runs collected across calls and closed with their message, maps (scalar and message values, `to_hash`), message instances, `extract!` from objects/Symbol/String keys, `set!` with attribute names, `merge!`, nil, names taken by Object methods, `encoded!`, descriptor binding, `Builder.message`/`write`/`new`/`target!` with a String prefix, `Message.build`, `message_class` through nesting, return values |
| `cache_test.rb` | 9 | miss stores the fragment's bytes (frozen) and a hit appends them without running the block; keys and options as given; caching per element inside a collection; `cache_if!`; no store; a hit or a miss marks fields written; a non-String and a corrupt cached value; caching while streaming to an IO |
| `coercion_test.rb` | 9 | Time, DateTime, pre-epoch times; Integer/Float/Rational/negative durations with nanosecond rounding; wrappers (`StringValue`, `Int64Value`, Hash form); WKT field blocks and instances; Struct and Hash to message; enums by Symbol/String/number, open enum numbers; Integer and Rational to double, FLT_MAX rounding, Infinity; ISO-8859-1/binary/US-ASCII strings; `to_h` map values |
| `error_test.rb` | 7 | 19 type/range errors with exact messages and paths (`friends[1].address.street`, `homes[1].city`, `places[7].city`, `attrs["k"]`, `attrs[:k]`), path stack clean after a rescue, unknown fields from `set!`/`merge!`/`extract!`/nested, misuse (block to a scalar or a map, collection missing, no value), every overwrite error including oneofs |
| `overwrites_test.rb` | 8 | late scalar wins (zero too) with exact bytes, nested message reopened and merged, oneof last-wins (message member included), append vs replace for strings/packed/messages, replace scoped per message |
| `streaming_test.rb` | 2 | 2,000 top-level elements reach the IO before the block ends, in buffer-sized writes; 5,000 elements through a pipe to a reading thread |
| `proto2_test.rb` | 8 | `proto2_unittest.TestAllTypes`: OptionalGroup/RepeatedGroup by block, Hash and instance, byte for byte; `encoded!` groups; caching inside a group; presence fields at default; unpacked repeated; `TestPackedTypes`; closed enum refuses 99, accepts -1 (NEG) |
| `ractor_test.rb` | 3 | builder classes shareable; building in another Ractor; a builder class first needed in another Ractor works and is not kept |
| `property_test.rb` | 107 | every message of every corpus golden's own file, 4 random instances each (`RandomMessage`, unknown fields off): a block replayed from `__to_h` (field methods where they exist, `set!` otherwise, a nested block per message, a collection block per repeated message) and `merge!` of the same hash both decode to `==` the original, and give identical bytes. Also run with 20 instances: 0 failures |

Whole suite: `bundle exec rake` clean (2,302 runs, 0 failures, 335 skips, as before plus 177 runs; standard clean) on
Ruby 3.2.2, 3.4.1 and 4.0.0. `rake shim:test`: 992 tests, 0 failures, 45 omissions (the shim was not modified).

## pbbuilder's own suite

Commit `3a071d5c6556c79eacd62d8f0501b122ac180bc7`. Appraisals name Rails 7.2 and 8.0. The script also runs 8.1, using
the Rails component gems (activesupport, activemodel, actionview, actionpack, railties) rather than the `rails`
meta-gem, which would pull in native-gem dependencies the tests never load.

| | Ruby 3.2.2 | Ruby 3.4.1 | Ruby 4.0.0 |
|---|---|---|---|
| shim, Rails 7.2 / 8.0 / 8.1 | 35 runs, 75 assertions, 0 failures, 1 skip (each) | same | same |
| builder (patch), Rails 7.2 / 8.0 / 8.1 | 35 runs, 75 assertions, 0 failures, 1 skip (each) | same | same |

The skip is pbbuilder's own (`skip("This will be addressed in a future version of this gem")`). No shim gap was
exposed, so the shim is unchanged.

### The fork (`llm/outputs/ws9-pbbuilder.patch`)

- `Pbbuilder` stays a `BasicObject` with `method_missing` and the same public methods. Its internals are one
  `Protostar::Builder` (`overwrites: true, repeated: :replace`): `set!`, `extract!` and `merge!` delegate, keeping
  pbbuilder's own `ArgumentError`s (unknown field, block to a non-message field, arity). The `_scope` swapping and
  the `||= msgclass.new` / `RepeatedField#replace` / `to_hash` guessing are gone. `target!` decodes the bytes once.
- `PbbuilderTemplate#cache!` calls `Builder#cache!` through a `FragmentStore` (Rails.cache wrapped in the
  controller's `instrument_fragment_cache`, the `SystemCallError` rescue kept). The cache holds wire bytes under the
  `:pbbuilder_bytes` namespace (was `:ppbuilder`, which holds Hashes).
- Collection partials: each element's body is its bytes, which is also what Rails' collection caching stores. The
  parent writes them with `encoded!`. The per-collection builder starts afresh for each element.
- `protobuf_extension.rb` is deleted: `Protostar::Message.build` is native. The gemspec depends on `protostar`. The test
  helper loads `test_proto_pb.rb` regenerated by `protostar compile`, so no protoc is needed. Appraisals lose
  their google-protobuf lines. The four test files are unchanged.

Behaviour that differs from pbbuilder on google-protobuf (none is covered by its suite):

1. **Collection partials no longer leak fields between elements.** Upstream renders every element into one shared
   message, so an element inherits fields it does not set. Checked on the shim: with racers A (logo `a.svg`) and B
   (no logo), upstream gives B `logo: {url: "a.svg"}`; the fork gives B no logo. The code path is the same on
   google-protobuf.
2. `target!` returns a new message when the message given to `new` was empty, which is always the case for templates
   and `build`. For a non-empty one, the built fields are laid over it as assignments: nested messages merge, maps
   merge, repeated fields are replaced. Upstream appends block-built elements to the existing ones in that case.
3. Wrong values raise `Protostar::Builder::Error` with a path instead of `Google::Protobuf::TypeError`/`RangeError`.
   `nil` writes nothing, where upstream raises for scalars and clears messages.
4. Mixing a list assignment and a collection block for the same repeated field in one message writes both: the
   block's elements stream, and the list comes when the message ends. Upstream's later call wins.

## Measurements

`script/pbbuilder_bench.rb`, Apple M-series. The template is a `Person` with `friends` over 1,000 Struct records. Each
element is wrapped in `pb.cache! racer` and holds a name, a last name, 2 tags, a bool, a nested `Asset` with 3 URLs,
and a 2-entry map. Rendering goes through ActionView with `perform_caching` and `Rails.cache` as a MemoryStore, as
pbbuilder's tests do; Rails 8.1. "Warm": every fragment hits. "Cold": the cache is cleared before each render, so
every fragment misses and is written. Times are medians of 15 renders; allocations come from one render. All rows
produce the same message, 204,472 bytes encoded. The real gem resolves with
`GEM_HOME=tmp/pbbuilder-bench/gem_home`. "builder, bytes out" is the fork with a measurement-only handler that
returns `@builder.target!` instead of decoding into a message, which shows what the handler's decode costs.

Ruby 3.4.1 (interpreter):

| | warm: ms | warm: allocations | warm, then encode: ms | cold: ms | cold: allocations |
|---|---|---|---|---|---|
| pbbuilder on google-protobuf 4.36.2 (C) | 23.0 | 72,937 | 23.2 | 45.2 | 132,411 |
| pbbuilder on the shim | 35.6 | 93,941 | 46.2 | 74.9 | 147,413 |
| pbbuilder on Protostar::Builder | 25.0 | 54,967 | 34.0 | 46.9 | 122,447 |
| same, bytes out | 16.2 | 37,968 | 16.2 | 37.1 | 105,449 |

Ruby 3.4.11 with YJIT:

| | warm: ms | warm: allocations | warm, then encode: ms | cold: ms | cold: allocations |
|---|---|---|---|---|---|
| pbbuilder on google-protobuf 4.36.2 (C) | 14.4 | 71,939 | 14.5 | 30.7 | 130,413 |
| pbbuilder on the shim | 18.0 | 92,944 | 19.8 | 32.5 | 145,416 |
| pbbuilder on Protostar::Builder | 11.8 | 53,969 | 12.4 | 20.3 | 120,449 |
| same, bytes out | 7.0 | 36,971 | 7.0 | 18.0 | 103,452 |

Where the builder's warm 25.0 ms goes (interpreter): about 9 ms is `target!` decoding the 204 KB back into 1,000
`Person`s with their `Asset`s and maps; about 7 ms is MemoryStore reads (it dups each entry) and fragment
instrumentation; the builder itself takes about 4 ms. A caller that sends bytes pays another 9 ms to encode the
message (1 ms under YJIT). Without Rails, the same 1,000 elements built with the builder take 4.6 ms and 1,020
objects; with a plain Hash as the cache store and every fragment a hit, 6.2 ms.

## Deviations from the spec, and why

1. **Builder classes are made on first use and kept on the message class (`@__builder`)**, not at definition time.
   conventions.md forbids lazily populated class-level caches. A builder class needs the union of field names over
   every message reachable from its root, and building that for every message at definition time would cost every
   user, builder or not (3,775 message types in the goldens). The cached value is a frozen, shareable class written
   only from the main Ractor; in another Ractor `Builder.for` makes a class each time and keeps none (tested). If
   that is unacceptable, `Types::Definer#setup` could make them eagerly at about one `class_eval` per message.
2. **`repeated: :replace` holds list assignments until their message ends.** The spec says nothing but packed runs is
   buffered. Replace mode is off by default; it holds references to the caller's lists (one `dup`), not bytes, and
   exists because pbbuilder's DSL assigns.
3. **`cache!` only calls `fetch`.** The spec lists `read`, `write` and `fetch` as what the store responds to; `fetch`
   is enough and avoids a second lookup on a miss. Rails.cache works as it is.
4. **Field names taken by `Object` or `Builder` methods get no method** (`hash`, `format`, `test`, `select`,
   `display`, ...) and are written with `set!`. The alternative was `::Kernel` in the builder's own code or a
   `BasicObject`, which the spec advises against.
5. **Field methods take `(value = NONE, &block)` only.** pbbuilder's `pb.friends coll, :name, :id` extract form is
   `set!(:friends, coll, :name, :id)`; a splat in every field method would allocate an Array per call.
6. **`nil` writes nothing**, for any field. That is not in the spec; it lets `extract!` and `merge!` take sparse
   objects.
7. **Additions:** `Builder#encoded!` (needed for collection partials, and generally useful for pre-encoded
   fragments), `Builder#message_class` (the fork validates against the current nested message), coercion of a scalar
   to a wrapper type, `Builder.new` with a String target to append to.
8. **Rails versions:** the suite runs 7.2, 8.0 (Appraisals) and 8.1. Rails 7.2 also passes on Ruby 4.0.

## Changes outside my files

- `lib/protostar.rb`: one `require_relative "protostar/builder"`, so that `Message.build` exists after
  `require "protostar"`.
- `Message.build` is defined in `lib/protostar/builder.rb` by reopening `Protostar::Message`; `message.rb` is untouched.
- Nothing in `shims/` changed.

## Found along the way

- **Shim gap, not exercised by pbbuilder:** `Google::Protobuf::Struct.from_hash({"a" => "x"})` raises
  `ArgumentError: Unknown field: a` on the shim. protostar's `WellKnown::Struct.from_hash` assigns with `msg[k] = v`,
  which the shim's prepended `[]=` (field names, as in the gem) shadows. Needs a fix in the shim or the mixin (WS6).
- The upstream pbbuilder collection-partial leak above is worth reporting to cheddar-me.
- Decoding is the largest single cost in the fork's warm render (9 ms of 25 ms). That is WS3/WS11 territory; a
  handler that returns bytes would remove both it and the encode that follows.

## For WS10 (docs, bench, release)

- Document `Protostar::Builder` and `Message.build` in the README; the class's YARD comment is the draft. Say plainly
  that `overwrites: true` output relies on merge semantics.
- `script/pbbuilder_bench.rb` belongs with the other benchmarks; it needs the clones (`script/pbbuilder_suite.rb shim`
  and `builder` first) and network access for the Rails gems.
- CI's `shim` job now clones pbbuilder from GitHub and installs Rails three times per Ruby; cache the generated
  bundles (`tmp/pbbuilder-suite/*`) or move these steps to one Ruby if the job gets slow.

## Open questions for WS10

1. Should the pbbuilder fork be offered upstream, and if so should its template handler gain a bytes-returning variant
   (`pb.target_bytes!` or a `:pbbuilder_bytes` handler)? It takes the warm render from 25.0 to 16.2 ms (from 34.0
   when the message is then encoded) and from 54,967 to 37,968 allocations. But it changes the public contract,
   which this workstream was told not to do.
2. Should builder classes be generated at definition time (deviation 1), trading definition time for strict adherence
   to the no-lazy-cache rule?
3. Is `Protostar::Builder::Error < Protostar::Error` right, or should type errors also be `::TypeError`s, as
   `Protostar::TypeError` is, so that `rescue TypeError` catches them?
4. Should `Wire::Writer` grow a way to splice a child buffer into its parent without copying (or should nested
   messages be sized ahead)? Each nesting level copies its bytes once into its parent. That is fine at 2–3 levels,
   but quadratic in depth for deeply nested trees.
