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
ruby 3.4.11 (2026-09-23 revision 592f1ffdb3) +PRISM [arm64-darwin24], Apple M1 Pro, 2026-10-19. Time per call; an empty cell has no counterpart on that side.

### Codec

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| decode TestAllTypes, 413 bytes | 34.2 µs | 8.07 µs | 2.87 µs | 2.77 µs |
| decode TestAllTypes, frozen: true | 38.0 µs | 9.91 µs |  |  |
| encode TestAllTypes | 16.4 µs | 7.15 µs | 0.88 µs | 0.87 µs |
| decode small message, 50 bytes | 4.22 µs | 1.79 µs | 1.09 µs | 0.93 µs |
| encode small message | 3.54 µs | 2.73 µs | 0.24 µs | 0.22 µs |
| decode 11 library catalogues, 4.9 MB | 146.7 ms | 101.6 ms | 10.0 ms | 9.7 ms |
| decode 11 library catalogues, frozen: true | 162.5 ms | 105.3 ms |  |  |
| encode 11 library catalogues | 86.5 ms | 25.1 ms | 7.1 ms | 7.4 ms |

### Views

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| large (1031 KiB): view, read two fields | 423.0 µs | 52.0 µs |  |  |
| large (1031 KiB): decode, read two fields | 996.3 µs | 308.2 µs | 220.4 µs | 225.5 µs |
| large (1031 KiB): view to_h | 1.9 ms | 688.9 µs |  |  |
| large (1031 KiB): decode to_h | 1.3 ms | 503.5 µs | 541.8 µs | 549.5 µs |
| small (314 bytes): view, read two fields | 22.3 µs | 6.70 µs |  |  |
| small (314 bytes): decode, read two fields | 24.7 µs | 6.45 µs | 3.59 µs | 3.16 µs |
| small (314 bytes): view to_message | 47.5 µs | 13.6 µs |  |  |

### Builder

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| 1,000 friends (203 KB): Protostar::Builder.build | 10.3 ms | 2.8 ms |  |  |
| 1,000 friends: new from Hashes, then encode | 14.5 ms | 7.3 ms | 1.5 ms | 1.4 ms |

### Loading a schema

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| define classes, unittest.proto and 3 imports (160 message classes) | 201.5 ms | 191.4 ms | 550.0 µs | 575.0 µs |
| load the generated Ruby (the DSL) and define classes, same files | 233.9 ms | 224.6 ms |  |  |
| Pool#add_serialized_file, same files, no classes | 19.4 ms | 12.5 ms |  |  |

### Compiler

| | protostar | protostar, YJIT | google-protobuf 4.36.2 (C) | google-protobuf (C), YJIT |
|---|---:|---:|---:|---:|
| lex unittest.proto | 15.7 ms | 4.1 ms |  |  |
| parse unittest.proto | 27.7 ms | 11.3 ms |  |  |
| compile unittest.proto, imports pooled, built-in descriptor.proto ready | 103.8 ms | 53.5 ms |  |  |
| compile unittest.proto, fresh Compiler | 132.9 ms | 79.7 ms |  |  |
| compile unittest.proto, retain_options: true | 114.2 ms | 68.0 ms |  |  |
| compile unittest.proto, source_info: true | 166.0 ms | 94.3 ms |  |  |
| compile descriptor.proto, fresh Compiler | 28.0 ms | 12.7 ms |  |  |
| emit native Ruby, unittest.proto and 3 imports | 13.1 ms | 8.8 ms |  |  |
| to_proto of unittest.proto, with source info | 33.9 ms | 13.7 ms |  |  |
| serialize unittest.proto, with source info | 21.0 ms | 8.1 ms |  |  |
| serialize unittest.proto, without source info | 8.5 ms | 3.8 ms |  |  |
| whole corpus, 107 files, a fresh Compiler each | 3.93 s | 1.92 s |  |  |
| whole corpus, source_info: true | 4.65 s | 2.44 s |  |  |

### Allocations (protostar, objects per call)

| | objects |
|---|---:|
| Codec: objects allocated by one TestAllTypes decode | 58 |
| Codec: objects allocated by one TestAllTypes encode | 1 |
| Codec: objects allocated by one library catalogue decode (424 KB) | 16806 |
| Views: objects allocated: large (1031 KiB), view, read two fields | 8 |
| Views: objects allocated: large (1031 KiB), decode, read two fields | 1519 |
| Builder: objects allocated: 1,000 friends, Protostar::Builder.build | 4019 |
| Builder: objects allocated: 1,000 friends, new from Hashes, then encode | 18007 |

<!-- rake bench: end -->

## Reading the table

**Decode and encode.** The C extension is 12 times faster at decoding a populated
`TestAllTypes` and 17 times faster at encoding it without YJIT; with YJIT the gaps are 3
and 8 times. On a 50-byte message protostar decodes in 1.8 µs and encodes in 2.7 µs with
YJIT, against the C gem's 0.9 µs and 0.21 µs. Per message that is rarely what an app
notices; per million messages it is.

**Library catalogues** (`bench/library.proto`) are large nested messages: eleven of about
440 KB, four levels deep, twenty elements in every repeated field, 4.9 MB in all. In a
process that has run only these classes, protostar decodes them in 31 ms and encodes them
in 25 ms with YJIT, against the C gem's 10 and 7 ms, and allocates 16,806 objects for one
catalogue. The decode row in the table, measured after the other codec rows, shows the
slowdown described next.

**Where the codec design comes from.** Keeping fields in instance variables set in one
fixed order, decoding nested messages from the parent's generated method, and encoding in
one pass with a length byte patched afterwards are ideas from
[protoboeuf](https://github.com/Shopify/protoboeuf), the pure-Ruby protobuf code generator
by Shopify's Ruby and YJIT folks, which showed how fast generated Ruby can decode protobuf
under YJIT. Thank you. On protoboeuf's own benchmark (`bench/fixtures/benchmark.proto`,
eleven parking lots, 5 MB, built with seed 42 as its `bench/benchmark.rb` does), measured
on 2026-10-19 with Ruby 3.4.11 and YJIT, protoboeuf decodes in 27 ms and protostar in 38,
and both encode in 25 ms; the C gem takes 13 and 10. protoboeuf writes its classes ahead
of time from protoc's output, while protostar builds them when the schema loads and spends
some of the difference on things outside protoboeuf's scope, such as the checks the
conformance suite asks for (UTF-8 validation among them). That comparison is not part of
`rake bench`, since it needs protoc and protoboeuf's generated classes.

**YJIT depends on what else ran.** Rows measured after other work can be much slower
than in a fresh process: catalogue decode takes 102 ms in the table and 31 ms alone. In
the slow state the generated decoders run in
the interpreter although YJIT compiled them; protostar's shared call sites are no longer
the cause, and what is is still open (llm/todos/yjit-polymorphic-call-sites.md). Tables
written before 2026-10-19 were also slowed by the harness itself, which ran every row
through one `n.times { yield }`.

**Views.** Reading two fields of a 1 MiB message through a view takes 52 µs with YJIT,
against 308 µs for decoding it with protostar and 226 µs with the C gem, and allocates 8
objects against 1,519. Without YJIT the view (423 µs) is twice as fast as protostar's
decode. When you want every field, decode: a view's
`to_h` costs what decoding does.

**Builder.** Writing 1,000 nested elements with `Protostar::Builder` takes 2.8 ms with
YJIT, under half of building the messages and encoding them (7.3 ms), and allocates a fifth
of the objects. The C gem's `new` and `encode` take 1.5 ms. llm/outputs/ws9-report.md has
the same comparison through pbbuilder and Rails, where the template engine and the cache
take most of the time; there the Builder was 9% behind pbbuilder on the C gem without YJIT
and 18% ahead with it.

**Loading a schema** is protostar's largest fixed cost: defining the 160 message classes
of `unittest.proto` and its imports takes about 200 ms (1.3 ms a class), because every
accessor, decoder, encoder and view reader is generated and compiled up front. The C gem
defers that work and takes about half a millisecond. Load the `_pb.rb` files you need,
at boot.

**The compiler** compiles `unittest.proto` (2,731 lines) in 133 ms from scratch and the
107 files of protobuf's test corpus in 3.9 s, 1.9 s with YJIT. protoc does `unittest.proto`
in about 20 ms, process start included (docs/compiler-internals.md, section 21).
