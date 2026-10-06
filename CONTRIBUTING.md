# Contributing to protostar

Contributions are welcome! Please take a moment to review this document so that
contributing stays easy and effective for everyone involved.

I'd especially love to get:

* `.proto` files or wire payloads that protostar handles differently from protoc or google-protobuf
* Gems depending on `google-protobuf` that do not run on the shim yet
* Performance work, especially on the generated encoders and decoders under YJIT
* Documentation fixes

## What do I need to know to help?

If you would like to learn more about the technologies protostar builds on, check out the (non-exhaustive) list below. You can also get in touch with me via an issue or email.

 - [ruby](https://ruby-doc.org)
 - The [protobuf language](https://protobuf.dev/programming-guides/proto3/) (proto2, proto3 and editions) and the [wire format](https://protobuf.dev/programming-guides/encoding/)
 - [descriptor.proto](https://github.com/protocolbuffers/protobuf/blob/main/src/google/protobuf/descriptor.proto), the schema of schemas that the compiler produces and the shim consumes
 - The [proto3 JSON mapping](https://protobuf.dev/programming-guides/json/) and the [text format](https://protobuf.dev/reference/protobuf/textformat-spec/)
 - google-protobuf's Ruby API, which the shim reproduces; its readable FFI implementation is the reference
 - [minitest](https://github.com/minitest/minitest) for testing

`docs/design.md` is the one-page map of the parts, `docs/schema-api.md` the descriptor API, and
`docs/compiler-internals.md` the compiler stage by stage.

## Issues and pull requests

* Opening an issue first is often the fastest way to get something in. I can shape it into something that fits the library.
* The most useful bug report is a small `.proto` file plus the bytes, JSON or text that misbehave, and what protoc or google-protobuf does with the same input. For the shim, the gem and version that breaks.
* I may close a PR and implement the idea differently. That's not a rejection of the idea, and you'll be credited (`Co-authored-by`).
* Feel free to propose opinionated changes, but be prepared that your opinion won't be shared. It is a give-and-take.

## Code changes

Please adhere to the coding conventions used throughout the project (indentation,
accurate and terse comments, etc.) and any other requirements (such as test coverage).

Run the `rake` default task to make sure code is properly formatted and documented. The
full gate before a PR is a bit longer, because protoc is the oracle for most of this
project and its expectations are recorded as fixtures:

* `rake test` runs the test files in a worker process per core; `PARALLEL=0 rake test` runs
  them in one, which is easier to debug. Make temp dirs with `tmpdir` and ports with
  `free_port`, and define classes into a registry of the test's own: the guards in
  `test/parallel/isolation_test.rb` fail otherwise
* `rake test:warnings` runs the suite under `ruby -w` and fails on any warning from `lib/`
* `rake shim:test` runs the `google-protobuf` shim's suite from its own bundle
* `rake bootstrap:check`, `rake examples:check` and `rake conformance:check` fail when a
  committed generated file is stale; the matching `:regenerate` tasks fix that
* `rake conformance:run` drives protobuf's official conformance runner (`rake conformance:build`
  once, it needs CMake and a C++ toolchain)
* `rake rbs:validate` and `rake yard` keep the signatures and the API docs honest

protoc is never needed to run the tests. `test/corpus/` holds protoc's own test files and the
descriptors protoc 36.2 produced for them; `rake corpus:goldens` regenerates those and is the
only task that needs protoc on the machine. Don't edit the corpus or the goldens by hand.

Two rules the whole codebase follows: no runtime dependencies and no native code, ever; and
everything reachable from a descriptor or a generated class is frozen and Ractor-shareable.

## Basic expectations

This project is something created with love, and I - as an author - expect you, as a contributor, to return the favor. The ground rules:

* Be polite and direct. No abrasiveness, no passive-aggression.
* [Low-context](https://www.ebsco.com/research-starters/communication-and-mass-media/high-context-and-low-context-cultures) communication is preferred and permitted
* No ad-hominems, also in code comments
* No sexualized or aggressive language

As a maintainer, I reserve the right to deny any contribution, discussion post, comment or pull request I find inappropriate.

Similarly, I reserve the right to not accept any contribution that doesn't fit the goals or spirit of the project (or my own), without explaining why it has been refused.

## Decisions are final

You're welcome to make your case once, clearly. After that, please don't reopen closed issues, start meta-threads about the decision, or argue about the wording of this document. This is a list of expectations, not a contract to be lawyered. If something isn't covered, the maintainer's judgment applies.

## What happens elsewhere stays elsewhere

Contributions are judged on what they are, not on who sent them. What anyone says or does outside this project (on social media, at their job, in other repos, in politics) is not a topic here and will not be considered, either for or against them. Please don't bring it in: no call-outs, no "are you aware this person…" threads, no requests to ban someone over things that didn't happen here.

## AI-generated issues and code

This project uses LLMs to produce code and artifacts, and it's fine if you do the same when contributing. LLM use in this project is settled: threads about whether it should be used (utility, harm, societal implications etc.) will be closed.

Please disclose LLM use in every issue and PR: say which model or tool you used and what for (e.g. "Claude wrote the fix, I wrote the test"). This is for transparency, not for judgment. Disclosed LLM use is treated the same as no LLM use.

However, the following is on you:

* Make your LLM output _terse._ Nobody likes reading slop, even my agents. Make it get to the point.
* Make sure what you submit actually ran. Don't file issues about behavior or APIs your LLM imagined.
* Do not add external dependencies (or have your LLM do it) unless absolutely necessary
* If you file a PR, make at least one pass with "Make this at least 50% less code"
* Code generated by your LLM will be considered as written by you, with the same requirements

## License

By submitting a patch, you agree to allow the project owner to license your work under the same license as that used by the project, which you can see [here](LICENSE.txt).
