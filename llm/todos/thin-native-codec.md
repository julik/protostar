# A thin native encoder/decoder, just to make encode and decode go brrrr

**Status:** feature lead from Julik, 2026-10-06. Not scheduled. Depends on the pure-Ruby
optimisation brief (`pure-ruby-codec-go-brrr.md`) having run first, so the native part only
covers what Ruby cannot reach.

## The one rule

protostar stays pure Ruby. The native codec is a separate, optional gem
(`protostar-turbo`, name to taste) that the pure-Ruby gem never depends on. Everything
else, the compiler, descriptors, generated classes, JSON, text, views, the builder, the
shim, keeps working without it. With it installed, `encode` and `decode` on the same
classes get faster and nothing else changes: same bytes, same objects, same errors.

That is the opposite of the google-protobuf design, where the whole object model lives in
C (upb arenas, handles into native memory, nothing inspectable). Here the object model
stays Ruby's; the native code only moves bytes into and out of ordinary Ruby objects.

## Shape

- **Thin** means a few hundred lines of C with no protobuf library underneath: a wire
  reader and writer (varint, zigzag, fixed32, fixed64, length-delimited, groups) and a
  table-driven message loop. No descriptors in C: at class-definition time protostar hands
  the extension a compact field table per class (number, wire type, slot index, kind, nested
  class, packed flag, presence flag, enum open/closed) as a frozen Ruby Array of Integers and
  class references, and the C loop walks that. New field kinds or semantics never need C
  changes unless the wire format changes, which it does not.
- **Decode** fills the same slot Array and presence bitmask the generated Ruby decoder
  fills, creating nested messages with `rb_obj_alloc` plus the same ivar stores, strings
  with `rb_utf8_str_new` or `rb_str_new` and a validity check, repeated fields as Ruby
  Arrays, maps as Ruby Hashes. Unknown fields are collected the same way. Errors raise
  `Protostar::DecodeError` with the same messages and offsets, so the error tests run
  against both codecs unchanged.
- **Encode** is a single pass with a growable C buffer, nested lengths back-patched, or a
  size pass in C (cheap there) then a write pass; either way the output bytes are identical
  to the Ruby encoder's.
- **Dispatch**: when the gem is present, `Types.define` installs `decode` and `encode`
  that call into C, with the pure-Ruby methods kept as `__decode_ruby` and `__encode_ruby`
  for the differential tests and as the fallback when a class uses something the C loop
  does not handle (it should handle everything, but the fallback keeps the contract honest).
  `PROTOSTAR_CODEC=ruby` forces the Ruby path at runtime.
- **Ractors**: the C functions touch only their arguments and the frozen field tables, no
  global mutable state, so they are callable from any Ractor; the field tables are made
  shareable like everything else at define time.
- **Views, JSON, text, builder** are out of scope for the native gem by design; they stay
  Ruby. If views ever want a native scan, that is a second brief.
- **Platforms**: a plain C extension with `extconf.rb`, no external libraries, compiled at
  install; precompiled binaries only if someone asks. Ruby 3.2+ C API only.

## What would be measured

The harness from the pure-Ruby brief, with a fourth and fifth column: "native" and
"native, YJIT". Targets: decode and encode within 1.5× of the google-protobuf C extension
on every row of the codec table (its remaining advantage is arena allocation and not
creating Ruby objects at all, which we refuse on purpose), and object construction cost
documented as the price of inspectable messages.

## Tests

- The whole existing codec suite runs twice, once per codec, through an environment switch
  in `test_helper.rb`; the differential test asserts byte-identical output and `==` objects
  for random messages from every corpus golden; the oracle and conformance suites run with
  the native codec on.
- `rake shim:test` with the native gem installed: the shim gains the speed for free.
- Valgrind or ASan in one CI job on the extension; fuzzing the decoder with truncated and
  bit-flipped corpus bytes for crashes (not correctness, the Ruby tests cover that).

## Effort

Medium: the C is small by design, and the table format and the test doubling are most of
the work. Do it only after the pure-Ruby brief has shown where the floor is, so the gem
earns its existence with a number.
