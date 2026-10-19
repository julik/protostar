# WS15: codec slots, one-pass encode, monomorphic decode

Branch `ws15-codec-slots`, from `4c613c3`. Ruby 3.4.11, M1 Pro, 2026-10-19. The machine
was shared with other test runs for most of the day (load average 7 to 60), so every
comparison below is either before and after measured back to back or the best of several
interleaved runs; absolute numbers move by 10 to 20% between runs.

## Result

`bench/library.proto` is a new benchmark: eleven library catalogues (shelves of slots
holding books with notes, four levels of nesting, twenty elements per repeated field),
4.9 MB. YJIT, ms per pass over the eleven, in a process that has run nothing else:

| | before | after |
|---|---:|---:|
| decode | 58.3 | **30.5** |
| decode, `frozen: true` | 151.7 | **36.4** |
| encode | 38.4 | **24.9** |
| objects allocated by one 424 KB decode | 25,419 | **16,808** |

Without YJIT: decode 206 → 151 ms, `frozen: true` 286 → 162 ms, encode 148 → 87 ms. The
google-protobuf C extension decodes the same bytes in about 10 ms and encodes them in
about 7 ms (`rake bench`).

`rake bench`, codec section, YJIT ("before" is `4c613c3` run with the new harness, step 5):

| | before | after |
|---|---:|---:|
| decode TestAllTypes, 413 bytes | 30.0 µs | 8.2 µs |
| decode TestAllTypes, frozen: true | 35.4 µs | 9.5 µs |
| encode TestAllTypes | 11.4 µs | 7.2 µs |
| decode small message, 50 bytes | 2.46 µs | 1.77 µs |
| encode small message | 3.58 µs | 2.67 µs |
| objects per TestAllTypes decode / encode | 76 / 5 | 58 / 1 |

Without YJIT, back to back: TestAllTypes decode 41 → 33 µs.

The catalogue rows in `rake bench` run after the other codec rows and are in the slowed
state described under "The YJIT cliff"; the fresh-process numbers are the ones above.

## The steps and what each bought

Catalogue benchmark, fresh process, YJIT unless noted (best of 2 × 5 rounds of 10 passes,
each commit's `lib/` measured back to back).

1. **Nested messages decoded from the parent's loop** (`221aa7f`).
   `__decode_fields(r, buf, pos, limit, depth, end_group, frozen)` takes the position and
   limit as arguments and returns the position; the `Wire::Reader` is only moved
   (`Reader#__seek`) before a slow path. Message and group fields call the child class's
   decoder from the parent's generated method, so each call site sees one class and stays
   monomorphic under YJIT. Recursion limit and error offsets as before. Decode 58.3 →
   48.4 ms; without YJIT 206 → 175 ms.
2. **Fields in instance variables** (`1ebe0e6`). One ivar per field named after its slot
   (`@_0`, `@_1`, …), so no field name can clash with `@unknown` or the shim's
   `@__gwrappers`, and all classes share one chain of shapes. A generated `__reset` sets
   `@unknown` then every slot in order, and every way of making a message goes through it
   (new, decode, dup, clear!, the shim's copies), so a class has one shape. Readers that
   return the variable as it is are copies of `attr_reader`s. Generic code uses generated
   `__slot(i)`, `__set_slot(i, v)`, `__slots`, `__load_slots`. Decode 48.4 → 37.7 ms,
   `frozen: true` 146 → 46 ms, allocations 25,419 → 16,808. `test/message/shape_test.rb`
   pins one shape and no "too complex" shape for TestAllTypes (80 fields) made eight ways.
3. **One-pass encode into a String** (`5d2705e`). `__encode` reserves one byte for a
   nested message or packed varint run, patches it, and `bytesplice`s more only past 127
   bytes; fixed-width packed runs know their length up front. The checks the sizing pass
   made run while writing, in the same order, so the same `EncodeError` comes first.
   `encode_to(io)` and `encode_delimited(io)` keep two passes. Encode 39.0 → 25.1 ms;
   without YJIT 141 → 93 ms. Tests: both paths agree at the 1-, 2- and 3-byte length
   boundaries for nested messages, packed runs, maps and delimited output, and for random
   instances of every corpus message.
4. **Enum names through a literal `case`, field tables as constants** (`82e9b91`). The
   decoder's methods live in a module of their own, included into the class, whose
   constants `I<n>` are the fields' `FieldInfo`s. Decode 37.2 → 31.4 ms.
5. **Benchmark harness** (`4994aa9`). `Bench.measure` ran every row through `n.times {
   yield }`; rows after the first measured up to 3× slower under YJIT than the same code in
   a plain loop. Older `rake bench` tables understate YJIT for all but their first row.
6. **Wide messages and per-class allocation** (`6e00602`). YJIT compiles `case` on an
   Integer as a chain of at most 20 guards; past that the remaining tags leave compiled
   code. Messages with more than 16 tags narrow the tag with `<` down to `case`s of 16.
   `__empty` is generated per class and the decoder allocates nested messages inline.
   TestAllTypes decode 9.7 → 8.3 µs, frozen 13.8 → 11.0 µs; the catalogue (at most 15
   tags a message) is unchanged.
7. **No Writer on the String path** (`ea4326a`). Long varints via `Wire.append_varint`,
   strings via `append_as_bytes` (3.4) or `pack("a*")` (3.2, 3.3). Small message encode
   0.95 → 0.71 µs; catalogue encode 25.6 → 24.7 ms.
8. **`freeze` per class** (`697f504`). Catalogue `frozen: true` decode 38.4 → 36.4 ms.
9. **The catalogue benchmark** (`d804b12`), in `rake bench` on both sides.

## What did not pay

- Enum lookup through a constant Hash (`E<n>[v]`) measured slower than the literal `case`.
- Index `while` loops instead of `each` for repeated fields in the encoder: small message
  unchanged, TestAllTypes encode 8.0 → 12.6 µs. Reverted.
- Constants holding the field classes themselves give anonymous classes a name
  (`#<Module:…>::M1`); the FieldInfo stands in at the cost of one attribute read.
- Inlining 3+ byte varints: not done. The benchmarks have few (catalogue values are
  0..400, TestAllTypes's are small or negative), so it would not have measured.

## What decode still pays for

Measured by switching them off in an experiment (none was kept off): UTF-8 validation of
strings costs about 8% of decode on large nested messages, and freezing decoded strings
about 5% more. Beyond
those, the decoder maps enum numbers to Symbols, masks and sign-extends int32 and uint32,
reads bools from any varint, checks every length against its limit and the recursion
limit per nested message, accepts packed and unpacked encodings of repeated scalars, and
keeps closed-enum unknowns and unknown fields. All of it is required for the conformance
suite, which still passes in full.

## The YJIT cliff

The lead in `llm/todos/yjit-polymorphic-call-sites.md` turned out to be three things:
shared call sites (fixed above), the harness (fixed), and a slowdown that is not in
protostar's call sites. After a process has decoded TestAllTypes 20,000 times, catalogue
decode takes 100 ms against 31 fresh. In that state the generated decoders run in the
interpreter (macOS `sample`: time in `vm_exec_core` and its `case` hash lookup) although
`--yjit-log` shows them compiled, and nothing is compiled or invalidated while it runs.
The base commit shows it too. Ruled out: GC, object shapes, the shared decode entry, the
constant names, YJIT thresholds and memory; `--yjit-stats` hides it. Details and a repro
are in the todo.

## Behaviour changes

- Message internals: fields are `@_<n>` ivars; `__values` is replaced by `__slot`,
  `__set_slot`, `__slots`, `__load_slots` (all `@api private`). `instance_variables` lists
  `@unknown` and the slots.
- Each class defines `freeze` (ending in `super`, so the shim's runs) and `self.__empty`;
  `Message#freeze` is documented with `@!method`. A test listing a class's own methods
  (protostar RBS) now ignores names Message already answers.
- Each class includes an anonymous module holding its decoder; it shows in `ancestors`.
- `__decode_fields` has a new signature (`@api private`; `View#to_message` updated).
- Encoding an invalid repeated element raises the same `EncodeError` as before, now while
  writing rather than from a sizing pass; `encode` returns nothing either way.
- New: `Wire.append_varint(buf, value)` (public, YARD), `Wire::Reader#__seek` (private).
- Defining classes costs more: the 160 classes of unittest.proto took about 200 ms against
  176 in the previous table, from the extra generated methods (`__slot`/`__set_slot`
  cases, `__reset`, `__encode`, `freeze`, the decoder module).
- `rake bench` numbers after the first row are not comparable with tables written before
  `4994aa9`.

## Checks

`bundle exec rake` (2,495 runs) and `rake test:warnings` clean on 3.4.1; tests green on
3.2.2 and 4.0.0. Oracle (`BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`): green, 0 skips.
`rake conformance:run`: 5,648 + 909 passed, the one expected failure. `rake shim:test`:
1,001 tests green. `bootstrap:check`, `conformance:check`, `examples:check`: current (the
generated `_pb.rb` format did not change). Ractor tests pass; `frozen: true` messages are
shareable (asserted for every corpus message by the property test).
