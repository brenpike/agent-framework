---
normalize-absent-canary: this forbidden frontmatter token is deliberately
  wrapped across lines so only whitespace-normalized matching detects it
---

# normalize-absent canary target

This file is the deliberately VIOLATING target for the `SAFETY-CANARY`
frontmatter-absent normalization self-test in `tools/policy_check.sh`. Its YAML
frontmatter carries the forbidden canary value WRAPPED across two lines: raw
substring matching cannot see the wrapped value as one word sequence, so only
whitespace-normalized frontmatter matching detects it. The self-test asserts
DETECTION — if the frontmatter-side normalization call is ever removed, the
violation goes unseen and the self-test fails the run.

A standing green fixture cannot witness this branch: for `absent` semantics a
raw-substring hit always survives normalization, so removing normalization can
only flip a red detection to green, never a green fixture to red. That is why
this target is asserted red by a self-test instead of pinned by a fixture (see
`tests/policy/README.md` rule 5).

This file is NOT a fixture (fixture discovery is `safety-*.json` at the
`tests/policy/` top level) and its canary key exists nowhere else, so no real
`absent` assertion ever matches it.

Do not unwrap the frontmatter value: the wrapping IS the test.
