# Benchmarks

What protostar costs, next to the google-protobuf C extension, on one machine. The table is
written by `rake bench` (`WRITE=1 rake bench` replaces it here); the numbers are reported,
never checked by a test.

```console
$ bundle exec rake bench            # print the table
$ WRITE=1 bundle exec rake bench    # and put it into this file
$ BENCH_ONLY=codec ruby bench/run.rb
```

Each column is a process of its own with no Bundler: protostar from `lib/`, and
google-protobuf 4.36.2 from a GEM_HOME under `tmp/bench/` that holds nothing else (it is
installed there on the first run). YJIT columns run the same Ruby with `--yjit`. A row is
the median time per call over batches of about 50 ms, after a warmup; compiler and loading rows are
the best of 10 calls (3 for the corpus). The files in `bench/` say what each row does, and
each runs on its own (`ruby bench/codec_bench.rb`, `BENCH_SIDE=google ...`).

<!-- rake bench: start -->
ruby 3.4.11 (2026-09-23 revision 592f1ffdb3) +PRISM [arm64-darwin24], Apple M1 Pro, 2026-10-06. Time per call; an empty cell has no counterpart on that side.

### Codec

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| decode TestAllTypes, 413 bytes | 42.9 µs | 30.5 µs | 3.07 µs | 2.71 µs |
| decode TestAllTypes, frozen: true | 57.0 µs | 36.8 µs |  |  |
| encode TestAllTypes | 30.0 µs | 11.9 µs | 0.92 µs | 0.88 µs |
| decode small message, 50 bytes | 5.26 µs | 2.54 µs | 1.09 µs | 0.90 µs |
| encode small message | 5.76 µs | 3.57 µs | 0.27 µs | 0.22 µs |

### Views

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| large (1031 KiB): view, read two fields | 446.6 µs | 52.9 µs |  |  |
| large (1031 KiB): decode, read two fields | 1.4 ms | 592.8 µs | 264.8 µs | 262.4 µs |
| large (1031 KiB): view to_h | 2.1 ms | 744.8 µs |  |  |
| large (1031 KiB): decode to_h | 1.8 ms | 760.5 µs | 588.4 µs | 597.5 µs |
| small (314 bytes): view, read two fields | 22.9 µs | 6.66 µs |  |  |
| small (314 bytes): decode, read two fields | 28.5 µs | 20.2 µs | 3.69 µs | 3.35 µs |
| small (314 bytes): view to_message | 51.4 µs | 27.2 µs |  |  |

### Builder

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| 1,000 friends (203 KB): Protostar::Builder.build | 10.1 ms | 2.7 ms |  |  |
| 1,000 friends: new from Hashes, then encode | 17.6 ms | 7.3 ms | 1.8 ms | 1.6 ms |

### Loading a schema

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| define classes, unittest.proto and 3 imports (160 message classes) | 175.9 ms | 180.8 ms | 540.0 µs | 554.0 µs |
| load the generated Ruby (the DSL) and define classes, same files | 207.7 ms | 203.0 ms |  |  |
| Pool#add_serialized_file, same files, no classes | 21.6 ms | 13.8 ms |  |  |

### Compiler

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| lex unittest.proto | 16.0 ms | 4.4 ms |  |  |
| parse unittest.proto | 29.0 ms | 11.8 ms |  |  |
| compile unittest.proto, imports pooled, built-in descriptor.proto ready | 89.1 ms | 76.2 ms |  |  |
| compile unittest.proto, fresh Compiler | 136.6 ms | 95.0 ms |  |  |
| compile unittest.proto, retain_options: true | 117.9 ms | 58.9 ms |  |  |
| compile unittest.proto, source_info: true | 166.4 ms | 108.2 ms |  |  |
| compile descriptor.proto, fresh Compiler | 27.1 ms | 14.5 ms |  |  |
| emit native Ruby, unittest.proto and 3 imports | 11.1 ms | 8.2 ms |  |  |
| to_proto of unittest.proto, with source info | 32.6 ms | 15.1 ms |  |  |
| serialize unittest.proto, with source info | 22.8 ms | 9.4 ms |  |  |
| serialize unittest.proto, without source info | 10.5 ms | 6.7 ms |  |  |
| whole corpus, 107 files, a fresh Compiler each | 4.23 s | 2.31 s |  |  |
| whole corpus, source_info: true | 4.88 s | 2.59 s |  |  |

### Allocations (protostar, objects per call)

| | objects |
|---|---:|
| Codec: objects allocated by one TestAllTypes decode | 76 |
| Codec: objects allocated by one TestAllTypes encode | 5 |
| Views: objects allocated: large (1031 KiB), view, read two fields | 8 |
| Views: objects allocated: large (1031 KiB), decode, read two fields | 2522 |
| Builder: objects allocated: 1,000 friends, Protostar::Builder.build | 4018 |
| Builder: objects allocated: 1,000 friends, new from Hashes, then encode | 19012 |

<!-- rake bench: end -->

## Reading the table

**Decode and encode.** The C extension is 14 times faster at decoding a populated
`TestAllTypes` and 33 times faster at encoding it without YJIT; with YJIT the gaps are 11
and 14 times. On a 50-byte message protostar decodes in 2.5 µs and encodes in 3.6 µs with
YJIT, against the C gem's 0.9 µs and 0.22 µs. Per message that is rarely what an app
notices; per million messages it is.

**YJIT depends on what else ran.** The codec's generated methods share helpers, and once
a process has run many message classes those call sites are polymorphic. The same small
encode measures 1.1 µs in a process that has run only that class and 3.3 µs after the
process has decoded other messages (here: the descriptors of the test fixtures, which
`rake bench` loads first). The code of the WS13 merge behaves the same way. Both numbers
are real; the second is what an app with more than one message type sees. Earlier reports
(12.9 µs for `TestAllTypes` decode under YJIT) were measured in a fresher process.

**Views.** Reading two fields of a 1 MiB message through a view takes 53 µs with YJIT,
against 593 µs for decoding it with protostar and 262 µs with the C gem, and allocates 8
objects against 2,522. Without YJIT the view (447 µs) is slower than the C gem's decode
but three times faster than protostar's. When you want every field, decode: a view's
`to_h` costs what decoding does.

**Builder.** Writing 1,000 nested elements with `Protostar::Builder` takes 2.7 ms with
YJIT, a third of building the messages and encoding them (7.3 ms), and allocates a fifth
of the objects. The C gem's `new` and `encode` take 1.6 ms. llm/outputs/ws9-report.md has
the same comparison through pbbuilder and Rails, where the template engine and the cache
take most of the time; there the Builder was 9% behind pbbuilder on the C gem without YJIT
and 18% ahead with it.

**Loading a schema** is protostar's largest fixed cost: defining the 160 message classes
of `unittest.proto` and its imports takes about 180 ms (1.1 ms a class), because every
accessor, decoder, encoder and view reader is generated and compiled up front. The C gem
defers that work and takes about half a millisecond. Load the `_pb.rb` files you need,
at boot.

**The compiler** compiles `unittest.proto` (2,731 lines) in 137 ms from scratch and the
107 files of protobuf's test corpus in 4.2 s, 2.3 s with YJIT. protoc does `unittest.proto`
in about 20 ms, process start included (docs/compiler-internals.md, section 21).
