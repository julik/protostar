# README install lines need the repository public

**Status:** blocked on the repo visibility, not on code. Noted by WS10 on 2026-10-06.

`gem "protostar", github: "julik/protostar"` and the shim's
`gem "google-protobuf", github: "julik/protostar", glob: "shims/google-protobuf/*.gemspec"`
resolve only once the repository is public; today an anonymous clone gets a 403. The same
forms resolve against a local clone in the shim's Bundler test, so the mechanism is proven.

When the repo goes public, or 0.1.0 is pushed to rubygems.org:

- Re-run the README install examples against a clean Gemfile and paste the real
  `bundle lock` output.
- Decide whether the shim stays git-only (its name is Google's on rubygems.org) or also
  ships from a private gem source; the shim README documents both.

Related, from the same report: Bundler 4.1.0.beta1's `override` keyword resolves the shim
route but `BUNDLE_FROZEN=true` then rejects the Gemfile (rubygems#9907, open). The
`bundler-override` plugin works on Bundler 4.0. Gems old enough to need an override, such
as googleapis-common-protos-types 1.4, ship pre-3.21 `_pb.rb` files, which the shim refuses
with `NotImplementedError` by design.
