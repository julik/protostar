# Codec speed under YJIT drops once many message classes are loaded

**Status:** open lead, not scheduled. Found by WS10 on 2026-10-06 (`llm/outputs/ws10-report.md`).

In a fresh process a small-message encode runs in about 1.1 µs under YJIT. Once the process
has exercised other message classes, the same encode on the same code takes 3.3 to 3.4 µs.
Both WS13's code and HEAD show it, so nothing regressed; the earlier reports measured the
fresh state and the benchmark now measures the loaded one (it loads fixtures through
`from_proto`).

Most likely cause: call sites shared by every generated encoder and decoder (the
`Wire::Writer` and `Reader` helpers, `Coercion`, the sizer entry points) become
polymorphic or megamorphic once many classes flow through them, and YJIT stops
specialising. Not pinned down.

How to attack it:

- Reproduce with `bench/codec_bench.rb` in a fresh process versus after loading the corpus.
- Use `RubyVM::YJIT.runtime_stats` (a YJIT-enabled Ruby built with stats) to find the
  exits and the megamorphic send sites in the generated code.
- Candidates: inline the hot writer and reader calls into the generated source instead
  of calling shared helpers; give each class its own copies of the shared fast paths;
  avoid `send`-style dispatch in the sizer.
- Keep the oracle and conformance suites green; report before and after on 3.4 with YJIT.

This is the best remaining performance lead; the interpreter numbers are unaffected.
