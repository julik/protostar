# WS1 report: the descriptor model (`Protostar::Schema`)

## What was built

`lib/protostar/schema.rb` and `lib/protostar/schema/`:

| File | Contents |
|---|---|
| `schema.rb` | `Schema::Error`, `Schema::ResolveError` (with `#name`, `#scope`), requires |
| `descriptor.rb` | `Descriptor` base: `name`, `full_name`, `index`, `options`, `features`, `inspect` |
| `file.rb`, `message.rb`, `field.rb`, `oneof.rb`, `enum.rb` (Enum, EnumValue), `service.rb` (Service, Method), `extension_range.rb` | the descriptor classes |
| `options.rb` | `Options`, `Options::EMPTY` |
| `features.rb` | `Features`, `EDITIONS`, `DEFAULTS` (transcribed with line citations) |
| `source_info.rb` | `SourceInfo`, `SourceInfo::Location` |
| `resolver.rb` | `Resolver.resolve(name, scope:, file:, pool: nil, types_only: true)` |
| `pool.rb` | `Pool` (Mutex-guarded) |
| `builder.rb` | `Builder.build(hash, pool:)`, `Builder.json_name(name)` |
| `default_value.rb`, `freezer.rb` | private helpers |

`lib/protostar.rb` now requires `protostar/schema`.

Test support: `test/support/golden_hash.rb` (`GoldenHash.load(json_path)`, `GoldenHash.convert`,
`GoldenHash.schema`), `test/support/schema_fixtures.rb` (build a golden into a pool),
`test/support/oracle.rb` (google-protobuf cross-checks, skip cleanly without it).

## Tests

211 runs, ~3400 assertions without the oracle (2 skips); 211 runs, ~3980 assertions, 0 skips with
`PROTOSTAR_ORACLE=1 BUNDLE_WITH=oracle`. Green on Ruby 3.2.2, 3.4.1 and 4.0.0. `standard` clean.

- `golden_round_trip_test.rb`: one test per golden `.json` (107): build every file of the set in
  order into a fresh pool, `file.to_h == hash` exactly, `Ractor.shareable?(file)`, caller's hash not frozen.
  No normalisation was needed for any protoc-produced hash.
- `source_info_test.rb`: hand-written locations, plus (oracle) every `.binpb` decoded with
  source info by google-protobuf, built and compared with `to_h`: all 107 sets round-trip
  including `source_code_info`.
- `golden_hash_test.rb`: conversion details, plus (oracle) `GoldenHash.load(json) ==
  FileDescriptorSet.decode(binpb).to_h` for all 107 goldens.
- `unittest_proto_test.rb`, `proto2_test.rb`, `proto3_test.rb`, `editions_test.rb`: the targeted
  assertions the spec lists across unittest, test_messages_proto2, basic_test_proto2,
  unittest_proto3, unittest_proto3_optional, map_unittest, unittest_custom_options,
  unittest_mset_wire_format, service_test, edition_unittest, unittest_delimited and
  test_messages_edition2023.
- `resolver_test.rb` (17): the descriptor.proto `type_name` rules and descriptor_unittest.cc's
  SearchMostLocalFirst(2), FieldTypeMayBeItsName, (Relative)FieldTypeNotAType,
  PackageOriginallyDeclaredInTransitiveDependent, public/private import visibility.
- `features_test.rb` (11): `DEFAULTS` equals the `edition_defaults` annotations read from
  descriptor.proto's golden, `EDITIONS` equals its `Edition` enum, per-edition defaults equal
  descriptor_unittest.cc's Proto2/Proto3/Edition2023/2024/2026 expectations, inheritance through
  every level, legacy proto2/proto3 spellings, custom feature merging, instance sharing.
- `pool_test.rb` (12): lookups, every clash protoc reports at pool level, concurrent `add` from
  8 threads, 16 racing clashing adds admit exactly one.
- `ractor_test.rb`: reads a built `unittest.proto` graph inside another Ractor; walks every
  reachable object of a file and asserts it is frozen.
- `builder_test.rb` (14): json_name rule, options with `:__extensions`/`:__unknown_fields`
  round-trip, default parsing, 24 malformed-hash cases, visibility/reserved round-trip.

Build cost: `unittest.proto` 13ms, `descriptor.proto` 3ms; all 237 file builds of the corpus 0.28s.

## Deviations from the spec, and why

1. **Features names.** The spec lists `default_symbol_value`; descriptor.proto has no such field.
   I used `default_symbol_visibility` (its real name) and added `enforce_proto_limits`, so
   `Features` has all 9 FeatureSet fields of v36.2. Defaults cover every edition up to
   `EDITION_2026` and `EDITION_UNSTABLE`, not only 2023/2024: corpus files use edition 2026.
2. **`Features#extensions`.** Custom features (`pb.cpp`, `pb.test`, ...) are merged down the tree
   as explicit values only. Their defaults would need the extension's own `edition_defaults`,
   which lives in another file; nothing in WS1 needs them.
3. **Extension ranges.** `Message#extension_ranges` is Array of inclusive Ranges as specified;
   the ranges' options and features live on `Message#extension_range_descriptors`
   (`ExtensionRange` objects), which `to_h` needs.
4. **Additions** beyond the spec: `File#option_dependencies`, `File#symbols`, `File#visible_files`,
   `File#edition_number`, `File#find_service`, `File#find_extension`; `Message#visibility`,
   `Message#extension_number?`; `Enum#visibility`, `Enum#open?`; `Field#real_oneof`,
   `Field#map_key`, `Field#map_value`; `Resolver.resolve(types_only:)`.
5. **`Resolver.resolve(pool:)` is optional.** Visibility comes from the file's linked
   dependencies; the pool is only used to produce protoc's "seems to be defined in X, which is
   not imported" message.
6. **`to_h` normalisation for hand-written hashes**: a missing `json_name` is computed, a missing
   `label` becomes `LABEL_OPTIONAL`, a missing `type` is inferred from what `type_name`
   resolves to, names gain their leading dot, `client_streaming: false` and
   `proto3_optional: false` are dropped, `package: ""` is dropped, Integer editions are named.
   Everything protoc produces round-trips unchanged.
7. **Within-file duplicate symbols raise** in the Builder. The spec leaves duplicates to the
   compiler, but a file's symbol table cannot hold two `Foo`s.

## Behaviour pinned where the spec was silent

- `Field#type` is `:group` and `#label` is `:required` when editions features say so
  (`DELIMITED`, `LEGACY_REQUIRED`), while `to_h` writes back `TYPE_MESSAGE`/`LABEL_OPTIONAL` as
  protoc's `CopyTo` does. A DELIMITED field stays `:message` when it is a map field or sits in
  a map entry (protoc's `PostProcessFieldFeatures`; tested on test_messages_edition2023).
- Float field defaults hold the nearest single-precision value (`-8e-28` becomes
  `-7.999999...e-28`); `to_h` keeps protoc's text.
- `Field#default` for enums is the first value's name as a Symbol, same type as `default_value`.
  For repeated fields it is the default of one element.
- `presence?` is true for extensions (protoc's Proto3ExtensionPresence).
- `scalar?` counts enums as scalars.
- A resolver lookup that ends on a package is "not defined"; protoc would return the package
  symbol, which no caller of a type lookup can use.

## Found along the way

- **`Ractor.make_shareable` is quadratic on descriptor graphs.** Every back-reference (field to
  message) makes it re-check the whole unflagged graph: 1.4s for unittest.proto. The Builder
  deep-freezes first, then calls `make_shareable`, which confirms in one pass (1.4s to under
  4ms). Anyone building shareable graphs with back-references (generated classes in WS3/WS4)
  should do the same.
- **The `.json` goldens lack `FieldOptions.FeatureSupport.removal_error`** (82 occurrences in
  options). They were printed by google-protobuf 4.31, whose descriptor.proto predates the field;
  the `.binpb` files have it. The oracle bundle now resolves to google-protobuf 4.36.2, which
  knows it. Regenerating the goldens with 4.36 would fix the JSON; I did not, since goldens are
  shared fixtures. The oracle test drops that key on purpose.
- The 4.31 JSON printer also wrote `EDITION_2026` and `EDITION_UNSTABLE` as numbers 1002 and
  9999. `GoldenHash` names them from the corpus descriptor.proto, so hashes always hold Symbols.

## Left out

- Option interpretation (`uninterpreted_option`, resolving `(my.option)` names) and option
  validation: that is the compiler's job. Options are stored verbatim.
- Symbol visibility (`export`/`local`, edition 2024) checks, naming-style enforcement, feature
  target/lifetime validation, duplicate numbers, reserved clashes, extension-range checks: compiler.
- `option_dependency` files are recorded by name but not linked or required in the pool.
- Weak dependencies must be in the pool like any other (protoc tolerates them missing).
- No binary decoding: source info from `.binpb` is tested only through the oracle.

## For the next workstreams

- **Compiler (WS2)**: produce exactly protoc's hash and `Builder.build` will link it; catch
  `ResolveError` (`#name`, `#scope`) to attach source positions. Things protoc's parser does that
  the Builder does not: synthesize map entry messages (`<Name>Entry`, `map_entry: true`, fields
  `key`=1/`value`=2) and **copy the map field's `features` onto the entry's key and value fields**
  (descriptor_unittest.cc MapFieldFeaturesOverride); synthesize `_name` oneofs for proto3
  `optional`; lower-case group field names (`group Data` makes field `data`, type `Data`); always
  emit `json_name` (`Builder.json_name`); write editions required/groups as
  `LABEL_OPTIONAL`/`TYPE_MESSAGE` plus features; omit `syntax` for proto2.
- **Codec (WS3)**: everything wire-relevant is resolved on `Field`: `type`, `wire_type`,
  `packed?`, `packable?` (accept both encodings when parsing), `presence?`, `delimited?`,
  `utf8_validation?`, `map?`/`map_key`/`map_value`, `enum_type.closed?`, `default`. Per-message
  lookup tables (`fields_by_number`, `fields_by_name`, `fields_by_json_name`) are frozen Hashes
  built once. Extensions: `Pool#find_extension(extendee, number)`, `Message#extension_number?`.
  Shareable side tables you build at class-definition time should be deep-frozen before
  `Ractor.make_shareable` (see above).
- **Shim (WS4)**: `Service#methods` and `Service#method(name)` shadow `Object#methods/#method`
  as the spec asked; avoid `obj.method(:x)` on a Service. `Pool` is per-process and mutable; the
  generated-pool singleton is yours to define.

## Open questions

1. Should `Field#default` for enum fields be the Symbol (as now) or the EnumValue/number? The
   codec may prefer numbers for open enums.
2. Should custom feature defaults (e.g. `pb.cpp`) be resolved when their FeatureSet extension is
   in the pool? Nothing needs them for Ruby today.
3. Regenerate the `.json` goldens with google-protobuf 4.36 so they carry `removal_error`?
