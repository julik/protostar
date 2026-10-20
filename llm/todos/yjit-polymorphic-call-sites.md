# Codec speed under YJIT drops once many message classes are loaded

**Status:** open lead, not scheduled. Found by WS10 on 2026-10-06 (`llm/outputs/ws10-report.md`);
narrowed by WS15 on 2026-10-19 (`llm/outputs/ws15-report.md`).

In a fresh process a small-message encode runs in about 1.1 µs under YJIT. Once the process
has exercised other message classes, the same encode on the same code takes 3.3 to 3.4 µs.
Both WS13's code and HEAD show it, so nothing regressed; the earlier reports measured the
fresh state and the benchmark now measures the loaded one (it loads fixtures through
`from_proto`).

## What WS15 fixed

- Shared call sites in the hot path are gone: nested messages are decoded from the parent's
  own generated loop, `__empty` and `freeze` are generated per class, and the String encoder
  no longer goes through `Wire::Writer`.
- Messages with more than 20 tags overflowed YJIT's guard chain on `case tag`; wide messages
  now split the dispatch into `case`s of at most 16 tags.
- Part of the "cliff" was the benchmark harness: `Bench.measure` ran every row's block through
  `n.times { yield }`, and rows after the first measured up to 3× slower than in a plain loop.
  It now uses a `while` loop.

## What is left: a 3× slowdown that is not in protostar's call sites

Repro (the library catalogues of `bench/codec_bench.rb`; Ruby 3.4.11, `--yjit`):

```ruby
require "./bench/fixtures"
k = BenchFixtures.test_all_types
b = k.new(BenchFixtures.all_fields).encode
i = 0
(k.decode(b); i += 1) while i < 20_000 if ENV["PRE"] # decode TestAllTypes first
lib = BenchFixtures.library
bins = BenchFixtures.libraries.map(&:encode)
# time: bins.each { |x| lib.decode(x) }  => 31 ms, 100 ms with PRE=1
```

The base commit (4c613c3) is in the slow state on this data either way (81 ms with or
without PRE, against 58 ms in a process that never defines the TestAllTypes classes); on
an earlier nested dataset it went from 78 to 221 ms with PRE. What was ruled out:

- not GC (`GC.disable` changes nothing), not object shapes (ivar shapes and embedding are
  the same either way; no class reaches 8 variations under `-W:performance`), not the
  shared `Message.decode`/`Decoder.decode` entry (calling the class's `__decode_fields`
  directly is just as slow), not the constant names in the decoder modules (unique names
  per class change nothing);
- not YJIT's thresholds or memory (`--yjit-call-threshold=1`, `--yjit-cold-threshold`,
  `--yjit-mem-size=1024` change nothing); no blocks are compiled or invalidated while the
  slow loop runs;
- `--yjit-stats` hides it: with stats both runs are equally slow and execute the same
  instructions in YJIT.

What `sample` (macOS) shows in the slow state: the time is in `vm_exec_core`, the
interpreter, with `rb_st_lookup` from its `opt_case_dispatch`, i.e. the generated decoders
run interpreted although YJIT compiled them (`--yjit-log` lists their blocks). The trigger
varies with the driver: in one script ten `TestAllTypes.__empty` calls were enough, in
another only real decodes were. Next step: a Ruby built with YJIT stats and
`--yjit-trace-exits`, or a reduced repro for the YJIT team.
