# WS8: zero-copy read-only views

Phase 2 of the message model: a read-only message over one buffer that never copies.
The "byte bag" from the brief. A view answers every reader the phase 1 message
answers, and `encode` hands back the bytes it was made from. Read `ws3-codec.md` and the
WS3 and WS5 reports first; the view must agree with the eager decoder on every input.

## Deliverables

`lib/protostar/view.rb` and `lib/protostar/view/` (the base class, per-class view
generation, lazy repeated and map wrappers, the index builder, `IO::Buffer` support),
tests under `test/view/`, a benchmark in `bench/view_bench.rb`.

## API

```ruby
v = Person.view(bytes)                       # String or IO::Buffer; no copy of the payload
v = Person.view(buffer, offset: 10, length: 200)
v.name                                       # same readers as Person: scalars, enums, has_x?, which_x
v.friends                                    # Protostar::View::Repeated, Enumerable, [], size, each, to_a
v.attrs                                      # Protostar::View::Map, [], key?, each, to_h, size
v.friends[2].name                            # a nested view over a slice of the same buffer
v.to_message                                 # the mutable phase 1 message, decoded eagerly
v.to_h, v.inspect, v == message, v.unknown_fields, v.descriptor
v.encode                                     # the original bytes of this view, byte for byte
v.frozen?                                    # always true; writers raise FrozenError
```

Rules:

- One scan builds a per-view index on first access: for every field number the
  occurrences in order, as offsets and lengths (or inline varint values). Nothing is
  decoded until a reader asks, and a decoded scalar or nested view is memoised so a
  second read is free.
- Merge semantics match the eager decoder exactly: last occurrence wins for scalars and
  oneofs, repeated occurrences concatenate (packed and unpacked mixed), a sub-message
  that occurs twice is one nested view over both slices, map entries overwrite by key.
  Closed-enum unknown numbers and unknown fields behave as in WS3.
- A nested view shares the parent's buffer; a `String#byteslice` is allowed only when a
  reader returns a string or bytes value, and `IO::Buffer#get_string` likewise. Field
  values that are not strings are read in place with `getbyte` and `unpack1` on a
  `byteslice` of at most 8 bytes or `IO::Buffer#get_value`.
- Views over a frozen `String` or a locked `IO::Buffer` are `Ractor.shareable?` after
  `freeze_index` (builds the index and memo tables eagerly, then freezes); a view
  created inside a Ractor from a shared buffer works without it.
- Per-class view classes are generated the way WS3 generates decoders: Ruby source,
  `class_eval`, one `case` on the tag in the index builder, readers with the slot number
  baked in. `Klass.view` returns an instance of `Klass::View`, a subclass of
  `Protostar::View`, created at `Types.define` time (keep the change to
  `lib/protostar/types.rb` to the registration hook and list it in the report).
- Malformed input raises `Protostar::DecodeError` with the offset, at index-build time,
  so a view that is handed back is well-formed at the top level; nested slices are
  checked when first touched.

## Testing

- Parity: for every message type in the corpus goldens, random messages from
  `test/support/random_message.rb` with unknown fields injected satisfy
  `Klass.view(bytes).to_h == Klass.decode(bytes).to_h`, `view.encode.equal?`-level
  identity with the input bytes for Strings, `view.to_message == Klass.decode(bytes)`,
  and `view == Klass.decode(bytes)`.
- Merge-rule cases hand-built on the wire: duplicate scalars, split repeated runs, mixed
  packed and expanded, a sub-message in two pieces, duplicate map keys, oneof last-wins.
- No-copy proof: reading a nested message's scalar from a 1 MiB message allocates no
  String longer than 8 bytes (count allocations with `GC.stat` deltas and
  `ObjectSpace`, or `allocation_stats` if you add it as a development dependency).
- `IO::Buffer` path on every CI Ruby, including a mapped file.
- Ractor: a frozen view crosses the boundary; a view is created inside a Ractor from a
  shared frozen String.
- Error cases with offsets, at the top level and in a nested slice.
- Benchmark: reading one scalar and one nested field from a large message, view versus
  eager decode, and full `to_h` of both, with the numbers in the report.

## Out of scope

Writable views, the shim, JSON or text output from views beyond `to_message` first.
