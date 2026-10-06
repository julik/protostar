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
the median time per call over batches of about 50 ms, after a warmup; compiler rows are
the best of 10 calls (3 for the corpus). The files in `bench/` say what each row does, and
each runs on its own (`ruby bench/codec_bench.rb`, `BENCH_SIDE=google ...`).

<!-- rake bench: start -->
ruby 3.4.11 (2026-09-23 revision 592f1ffdb3) +PRISM [arm64-darwin24], Apple M1 Pro, 2026-10-06. Time per call; an empty cell has no counterpart on that side.

### Codec

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| decode TestAllTypes, 413 bytes | 42.5 µs | 30.1 µs | 2.97 µs | 2.87 µs |
| decode TestAllTypes, frozen: true | 56.4 µs | 36.1 µs |  |  |
| encode TestAllTypes | 29.8 µs | 11.5 µs | 0.93 µs | 0.92 µs |
| decode small message, 50 bytes | 5.24 µs | 2.49 µs | 1.10 µs | 0.95 µs |
| encode small message | 5.79 µs | 3.53 µs | 0.28 µs | 0.23 µs |

### Views

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| large (1031 KiB): view, read two fields | 442.8 µs | 53.3 µs |  |  |
| large (1031 KiB): decode, read two fields | 1.4 ms | 556.7 µs | 271.3 µs | 274.1 µs |
| large (1031 KiB): view to_h | 2.0 ms | 716.2 µs |  |  |
| large (1031 KiB): decode to_h | 1.7 ms | 738.4 µs | 596.3 µs | 641.8 µs |
| small (314 bytes): view, read two fields | 22.4 µs | 6.54 µs |  |  |
| small (314 bytes): decode, read two fields | 28.3 µs | 20.0 µs | 3.64 µs | 3.50 µs |
| small (314 bytes): view to_message | 51.1 µs | 26.9 µs |  |  |

### Builder

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| 1,000 friends (203 KB): Protostar::Builder.build | 10.1 ms | 2.5 ms |  |  |
| 1,000 friends: new from Hashes, then encode | 17.5 ms | 7.1 ms | 1.8 ms | 1.7 ms |

### Loading a schema

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| define classes, unittest.proto and 3 imports (160 message classes) | 203.8 ms | 188.9 ms | 708.8 µs | 685.4 µs |
| load the generated Ruby (the DSL) and define classes, same files | 224.4 ms | 232.0 ms |  |  |
| Pool#add_serialized_file, same files, no classes | 22.4 ms | 13.5 ms |  |  |

### Compiler

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| lex unittest.proto | 15.7 ms | 3.9 ms |  |  |
| parse unittest.proto | 28.1 ms | 11.8 ms |  |  |
| compile unittest.proto, imports pooled, built-in descriptor.proto ready | 105.1 ms | 57.4 ms |  |  |
| compile unittest.proto, fresh Compiler | 135.4 ms | 90.0 ms |  |  |
| compile unittest.proto, retain_options: true | 115.5 ms | 76.4 ms |  |  |
| compile unittest.proto, source_info: true | 165.8 ms | 102.7 ms |  |  |
| compile descriptor.proto, fresh Compiler | 27.1 ms | 13.1 ms |  |  |
| emit native Ruby, unittest.proto and 3 imports | 11.2 ms | 8.5 ms |  |  |
| to_proto of unittest.proto, with source info | 32.6 ms | 15.7 ms |  |  |
| serialize unittest.proto, with source info | 22.9 ms | 9.6 ms |  |  |
| serialize unittest.proto, without source info | 10.4 ms | 4.9 ms |  |  |
| whole corpus, 107 files, a fresh Compiler each | 4.32 s | 2.29 s |  |  |
| whole corpus, source_info: true | 4.85 s | 2.39 s |  |  |

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
`TestAllTypes` and 32 times faster at encoding it without YJIT; with YJIT the gaps are 10
and 13 times. On a 50-byte message protostar decodes in 2.5 µs and encodes in 3.5 µs with
YJIT, against the C gem's 0.95 µs and 0.23 µs. Per message that is rarely what an app
notices; per million messages it is.

**YJIT depends on what else ran.** The codec's generated methods share helpers, and once
a process has run many message classes those call sites are polymorphic. The same small
encode measures 1.1 µs in a process that has run only that class and 3.3 µs after the
process has decoded other messages (here: the descriptors of the test fixtures, which
`rake bench` loads first). Both numbers are real; the second is what an app with more than
one message type sees. Earlier reports (12.9 µs for `TestAllTypes` decode under YJIT)
were measured in a fresher process; the code is the same speed, the process is not.

**Views.** Reading two fields of a 1 MiB message through a view takes 53 µs with YJIT,
against 557 µs for decoding it with protostar and 274 µs with the C gem, and allocates 8
objects against 2,522. Without YJIT the view (443 µs) is slower than the C gem's decode
but three times faster than protostar's. When you want every field, decode: a view's
`to_h` costs what decoding does.

**Builder.** Writing 1,000 nested elements with `Protostar::Builder` takes 2.5 ms with
YJIT, a third of building the messages and encoding them (7.1 ms), and allocates a fifth
of the objects. The C gem's `new` and `encode` take 1.7 ms. llm/outputs/ws9-report.md has
the same comparison through pbbuilder and Rails, where the template engine and the cache
take most of the time; there the Builder was 9% behind pbbuilder on the C gem without YJIT
and 18% ahead with it.

**Loading a schema** is protostar's largest fixed cost: defining the 160 message classes
of `unittest.proto` and its imports takes about 200 ms (1.3 ms a class), because every
accessor, decoder, encoder and view reader is generated and compiled up front. The C gem
does the same work lazily, in under 1 ms. Load the `_pb.rb` files you need, at boot.

**The compiler** compiles `unittest.proto` (2,731 lines) in 135 ms from scratch and the
107 files of protobuf's test corpus in 4.3 s, 2.3 s with YJIT. protoc does `unittest.proto`
in about 20 ms, process start included.
