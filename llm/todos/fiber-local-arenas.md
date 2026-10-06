# Fiber- or thread-local arenas for allocation

**Status:** idea from Julik, 2026-10-06. Nebulous on purpose; an experiment, not a plan.

## The thought

The C extension is fast partly because upb allocates every message of a decode in one
arena and frees it in one go. Ruby cannot free in bulk, but it can *reuse* in bulk: a
per-Fiber (or per-Thread) arena of pre-made objects that a decode draws from and a caller
hands back when a request is done, so a hot loop that decodes and discards the same shapes
stops paying for allocation and GC pressure. Where it could pay: request handlers and
workers that decode a message, read a few fields and move on; Builder renders that make
thousands of short-lived nested messages; the view scan's index Arrays.

## Things to try, cheapest first

1. **Measure before believing.** Count allocations per decode and encode by kind (slot
   Arrays, Strings, repeated Arrays, map Hashes, message objects, presence Integers) with
   `ObjectSpace.trace_object_allocations` on the benchmark shapes, and time GC's share of a
   decode loop (`GC.stat(:time)` deltas, `GC.disable` runs). If GC is under 10% of the
   loop, stop here and write that down.
2. **Scratch buffers, not objects.** The encoder's output String, the sizer's size Array
   and the view scan's index Array are the easy reusable things: keep one per Fiber in
   `Fiber[:protostar_scratch]` (Ruby 3.2's fiber storage, inherited by child fibers) and
   `clear` instead of allocate. This is low-risk, since those never escape to the caller.
3. **Message pools with explicit release.** `Klass.decode(bytes, arena: arena)` draws slot
   Arrays and message shells from `arena`; `arena.release` puts them back; anything that
   escaped (the caller kept a reference) is the caller's problem, documented loudly, as
   with any pool. Fiber-local by default via `Protostar.arena { |a| ... }`, which also makes
   it safe under Fiber-based servers (Falcon) and threads (Puma), since nothing is shared.
   Frozen messages can never come from a pool.
4. **Flyweight reads.** The WS11 lazy-readers brief already has a `flyweight: true` mode
   where one cursor is re-pointed per element; that is an arena of size one and the same
   idea taken to the limit. If WS11 lands, measure it against the pool.
5. **String reuse.** Ruby Strings cannot be re-pointed at new bytes, but `String#replace`
   into a pooled String of the right size avoids a malloc for short strings; only worth it
   if step 1 shows Strings dominate, and it fights with frozen-string expectations.
6. **GC tuning instead of arenas.** Sometimes the honest answer: document
   `RUBY_GC_HEAP_INIT_SLOTS`, `RUBY_GC_HEAP_GROWTH_FACTOR` and `GC.config(rgengc_allow_full_mark: false)`
   (3.4) for decode-heavy processes, with measured numbers, before building a pool.

## Ractor and Fiber rules

Arenas are per-Fiber and never shared: no global free lists, no Mutex. A Ractor gets its
own because fiber storage is per Ractor. A pooled object must be unfrozen and unshared,
which is why frozen or shareable messages are excluded.

## What would show it works

The codec benchmark table gains "arena" columns for decode and Builder rows, with
allocations per call next to time per call, in a loop that decodes, reads two fields and
releases. The number that matters is end-to-end throughput of that loop including GC, not
the single-call time. If the arena wins under 20% on the loop that favours it most, the
experiment ends with a note and no new API.

## Risks

Pools are where use-after-release bugs live; the API must make the escape hatch obvious
(`arena: nil` is always safe) and the default behaviour unchanged. Nothing here may touch
the frozen, shareable or `decode(frozen: true)` paths.
