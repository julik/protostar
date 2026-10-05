# WS8 report: zero-copy read-only views

## What was built

| File | Contents |
|---|---|
| `view.rb` | `Protostar::View`, the base class; `Message.view`, `Message.view_class`, `Message.__view_class` |
| `view/generator.rb` | per message class: a `View` subclass with a generated index builder (`__scan`) and readers, `class_eval`ed |
| `view/scan.rb` | the scan's rare paths (unknown fields, groups, packed checks, closed enums) and position-to-value decoding |
| `view/repeated.rb` | `View::Repeated`: Enumerable, `[]` (index, negative, start+length, range), `size`, `each`, `to_a`, `==` with Arrays |
| `view/map.rb` | `View::Map`: `[]`, `fetch`, `key?` and aliases, `keys`, `values`, `each`/`each_pair`, `to_h`, `size`, `==` with Hashes |
| `view/source.rb` | `View::Cursor` (a `Wire::Reader` over any buffer) and `View::IOSource` (IO::Buffer behind `getbyte`/`byteslice`/`unpack1`) |
| `bench/view_bench.rb` | the benchmark below |
| `test/view/*_test.rb`, `test/support/view_support.rb` | tests below |

### API

```ruby
v = Person.view(bytes)                                    # String or IO::Buffer
v = Person.view(buf, offset: 10, length: 200, recursion_limit: 100)
v.name; v.has_name?; v.which_kind; v[:name]               # the message's readers
v.friends                                                 # View::Repeated
v.attrs                                                   # View::Map
v.to_message(frozen: false); v.to_h; v.inspect; v.unknown_fields; v.descriptor
v.encode                                                  # the input String itself when the view covers all of it
v == message; v == other_view
v.freeze_index                                            # read everything, freeze; shareable over a frozen String
Person::View, Person.view_class, Person::View.message_class
```

### How it works

- A view holds the buffer, its segment (offset, length, or a flat list of segments for a merged
  message), the remaining recursion depth, and one Array, the index. For a class with `n` fields:
  `[0, n)` per field an inline varint value, an offset, a segment list, or the entries of a repeated or
  map field; `[n, 2n)` lengths; `[2n, 3n)` decoded values once read; `3n` unknown-field ranges; `3n+1`
  the `UnknownField` list once asked for.
- The index is built in the constructor: making a view scans its top level, making a nested view
  (on first read of the field) scans that. Nested content is skipped by its length, never read.
- The scanner is generated like WS3's decoder: one `case` on the whole tag, one- and two-byte varints
  inline, slot numbers baked in. The fold follows the eager decoder's rules with positions instead of
  values: singular scalars overwrite, oneof members clear their siblings, a singular message that
  occurs again appends a segment, repeated fields append `(value or offset, -1)` for one element or
  `(offset, length)` for a packed run, closed-enum unknown numbers (singular, unpacked, packed, map
  values) go to the unknown-field ranges in wire order.
- Readers: varint kinds convert the inline value (no memo needed); fixed kinds `unpack1` at the offset;
  strings and bytes `byteslice`; messages become nested views; all but varints are kept in the memo.
- Views are really frozen (`Object#freeze` at the end of the constructor); the index Array stays
  mutable for the memo until `freeze_index` fills and freezes it.
- `to_message` runs WS3's generated `__decode_fields` over a `View::Cursor` on each segment in turn,
  so it decodes an IO::Buffer in place too.

## Tests

172 runs are WS8's (1710 in the suite). `bundle exec rake` clean: 1710 runs, 82293 assertions, 0
failures, 335 skips (all pre-existing oracle and WS1 skips). Same counts on Ruby 3.4.1, 3.2.2 and 4.0.0.

| File | Runs | Covers |
|---|---|---|
| `parity_test.rb` | 108 | every message of every golden's own file (107 goldens), 4 random messages each with injected unknown fields: `to_h` equal to decode's (NaN-aware), `encode` `assert_same` as the input, `to_message == decode`, `view == decode`, unknown fields equal at every nesting level, and the same `to_h` again after `freeze_index` with `Ractor.shareable?` true. Plus readers, `has_` and `which_` compared field by field on TestAllTypes |
| `merge_test.rb` | 15 | hand-built wire: duplicate scalars, split repeated runs, packed and expanded mixed (varint and fixed, both directions, empty runs), a sub-message in three pieces (one view, three segments), groups in pieces, an over-long end-group tag, duplicate map keys (scalar and message values, missing key/value), a map message value in two pieces within one entry, oneof last-wins including a message member re-set after a sibling, closed enums (singular, unpacked, packed, map value), open enums, wire type mismatches, over-long tags and values, every proto2 default of TestExtremeDefaultValues |
| `error_test.rb` | 21 | 15 top-level malformations, packed runs, nested message, repeated element, map entry, invalid UTF-8, recursion limit; each asserted to raise `DecodeError` with **the same message and offset** as `decode` |
| `api_test.rb` | 13 | the API above, memoisation (`assert_same` on second reads), writers raising FrozenError, offset/length framing, inspect, a nested type named `View`, fields named `encode`, `to_message`, `hash`, `class`, `__f0` |
| `no_copy_test.rb` | 4 | 1.5 MiB message: reading a nested scalar, the 1000th element of a repeated message, and a field through an IO::Buffer allocates no String over 8 bytes (`ObjectSpace.trace_object_allocations`, GC off) and fewer than 20 objects; positive control: reading one 1 KiB string allocates exactly one 1024-byte String |
| `io_buffer_test.rb` | 7 | parity with String views, every fixed-width kind (NaN, -0.0), offset/length into a buffer, a `IO::Buffer.map`ped file, a locked buffer, malformed input |
| `ractor_test.rb` | 4 | view classes and the empty containers shareable; a `freeze_index`ed view crosses into a Ractor; views (maps included) made inside a Ractor from a shared String; errors inside a Ractor |

## Benchmark

`bench/view_bench.rb`, Apple M-series. "Large" is TestAllTypes at 1,056,512 bytes (a 512 KiB bytes
field, 512 strings of 1 KiB, 1000 nested messages); "small" is a populated TestAllTypes at 314 bytes.
"Two fields" is `view(bytes)` or `decode(bytes)` followed by reading `optional_int32` and
`optional_nested_message.bb`.

| | 3.4.1 interpreter | 3.4.11 YJIT |
|---|---|---|
| large, view, two fields | 428 µs | 76 µs |
| large, decode, two fields | 1.42 ms | 509 µs |
| large, view `to_h` | 1.88 ms | 904 µs |
| large, decode `to_h` | 1.74 ms | 751 µs |
| small, view, two fields | 22.0 µs | 7.5 µs |
| small, decode, two fields | 27.1 µs | 19.5 µs |
| small, view `to_h` | 74.8 µs | 42.4 µs |
| small, decode `to_h` | 45.1 µs | 29.6 µs |
| small, view `to_message` | 49.3 µs | 27.2 µs |

Objects allocated reading two fields: large 9 (view) vs 2522 (decode); small 28 vs 47.

What bounds the view: the top-level scan must still read every tag and length (protobuf has no skip
index); on the interpreter that is ~250 ns per top-level field on this machine (a bare loop doing only
that measures the same), under YJIT ~30 ns. Full `to_h` through a view is 1.1-1.7x slower than decode's:
it does the same decoding plus wrappers and per-field dispatch. Use `to_message` when everything is wanted.

Defining classes gets slower: unittest.proto and its imports take 127 ms with views against 68 ms
without (~0.3 ms per class, nearly all of it compiling the generated source).

## Deviations from the spec, and why

1. **IO::Buffer views cannot be Ractor-shareable.** `Ractor.make_shareable` refuses every IO::Buffer on
   3.2, 3.4 and 4.0 (locked, readonly or frozen alike), so a view holding one cannot be shareable.
   `freeze_index` still works on them; the test pins `Ractor.shareable?` false. Use a frozen String to
   share across Ractors.
2. **Invalid UTF-8 is reported when the string is read**, not when the view is made. Validating at
   scan time would allocate a String per string field, defeating the point. The message and offset are
   decode's. All structural malformation (tags, lengths, truncation, groups, packed runs) is still
   caught when the view is made.
3. **The index is built when a view is made, nested views included** (on first read of the field in
   the parent), rather than "on first access" of the view. Making a view is the first access: a top-level
   view must be checked before it is handed back, and a nested view is made when it is first touched.
   This also lets views be truly frozen without a mutable holder.
4. **`Klass::View` is not set when the message has a nested type that would be called `View`**
   (otherwise `Types.assign_constants` would silently skip that nested type). `Klass.view_class` always works.
5. **Recursion-limit errors carry the nested message's first byte as offset**, decode gives the tag's.
   Every other error matches decode's message and offset exactly (pinned by `error_test.rb`).
6. **Repeated scalars are decoded together on first use**, not one by one: a packed varint run cannot
   be indexed without reading it. String, bytes and message elements are decoded one at a time.
7. **`to_h` is field by field** (Message's `__to_h`). Well-known mixins (Struct's plain-Hash `to_h`,
   Any, Timestamp helpers) are not included in view classes; call `to_message` for those. The spec
   lists no JSON/text from views, and mixins are message-side helpers.
8. **`message == view` is false** while `view == message` is true: `Message#==` checks `instance_of?`
   and lives in WS3's file. Making it symmetric needs one line in `Message#==` (see below).

Additions: `recursion_limit:` on `view`, `to_message(frozen:)`, `to_proto` alias, `[]`, `pretty_print`,
`hash`/`eql?`, `View.message_class`, `Message.view_class`, `Repeated#to_ary` (so `[1, 2] == repeated`
holds), `Map#fetch`.

## Changes to other workstreams' files

- `lib/protostar/types.rb`: one line in `Definer#setup`, after the encoder:
  `View::Generator.install(klass, fields, oneofs)`.
- `lib/protostar.rb`: `require_relative "protostar/view"` after `text` (it must come after everything
  that adds public methods to `Message`, since those names are reserved from view readers).
- `lib/protostar/view.rb` reopens `Message`'s singleton class to add `view`, `view_class` and the
  `__view_class` reader (the generator sets `@__view_class` on each message class). No WS3 file was edited for that.

Nothing under `schema/`, `codec/`, `wire/`, `json/` or `text/` was modified. `View::Cursor` subclasses
`Wire::Reader` to skip its String-only constructor (which copies an IO::Buffer whole); everything else in
Reader, and WS3's generated decoder, run unchanged over it.

## Requests for other workstreams

- **WS3 (`Message#==`)**: to make equality symmetric, `return other == self if other.is_a?(View)` at the top
  of `Message#==`. Reason: a view should compare equal from either side.
- **WS3 (`Wire::Reader#initialize`)**: if it accepted any object answering `getbyte`/`byteslice`/`unpack1`
  (or an IO::Buffer without `get_string`), `View::Cursor` would not need to bypass the constructor and
  `Message.decode(io_buffer)` would stop copying the buffer whole.
- **WS4**: generated code that assigns nested constants must not assume `Klass::View` is free; it is taken
  by the view class unless a nested type of that name exists. If WS4 defines constants before
  `Types.define` (unlikely), it should do the same check as `Generator.view_constant_taken?`.
- **WS6 (shim)**: views have no google-protobuf counterpart; nothing to map.

## Open questions

1. Should `Klass::View` be the constant at all, given the clash rule? `Klass.view_class` alone would avoid
   the special case.
2. Should view classes include the well-known mixins (Any#unpack, Timestamp#to_time) for read-only use?
   Several assume they can call writers.
3. Define time nearly doubles. Generating view classes lazily would break the "no lazy class-level state"
   rule (and Ractor use); keeping them eager costs ~0.3 ms per class. Acceptable?
4. Is a thread-safety note enough? Two threads reading one unfrozen view may both decode a field; both get
   equal values, one wins the memo slot. Nothing is corrupted because the index is complete before the view
   is handed out.
