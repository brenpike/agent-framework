# Pin-Authoring Contract

This directory holds the `safety-*.json` consumer-assertion fixtures evaluated by
`tools/policy_check.sh` (P3 governance triples — see `docs/engineering-principles.md`).
You are reading this because you are about to add or edit a fixture. This file is the
authoring contract: every rule below states the invariant it enforces first, then the
mechanism that enforces it. Read the whole thing before pinning anything.

This README is invisible to the fixture loader: discovery is
`find tests/policy -maxdepth 1 -name 'safety-*.json'` (`tools/policy_check.sh:1473`),
so only `safety-*.json` files are ever evaluated.

## 1. Honest capability statement

**Invariant: a fixture must never claim more than the mechanism can deliver — an
overclaimed pin is a false sense of protection, which is worse than no pin.**

A pin CAN claim exactly one thing: "this word sequence exists in these specifically
named files; deleting it is loud." A pin CANNOT:

- claim meaning;
- detect a rewrite-around or a meaning inversion that leaves the pinned bytes intact;
- see files it does not name;
- assert body-prose ABSENCE — `absent: true` is scoped to YAML frontmatter by an
  explicit invariant in `tools/policy_check.sh`.

Pretending to more than this is exactly how the Problem-2 defect shipped. When you
write a fixture `description`, state what the pin honestly guarantees, not what you
wish it guaranteed. State it as a standing invariant in the present tense and make it
self-contained: no issue numbers, no PR references, no "re-pin"/"this change"
archaeology — the reader is a future author asking why this pin is claim-carrying,
not someone reconstructing history.

## 2. Pin the claim-carrying clause

**Invariant: the pin must sit on the words that carry the rule's claim, so that
rewriting the claim away turns the suite red.**

The claim-carrying clause is whichever clause — or clauses — ALTERATION OF would change
what the rule requires. In a conditional rule that is normally BOTH the discriminating
condition and the obligation it triggers: either one pin spanning both clauses, or two
pins, one per clause.

Real incident, as the failure mode: a rule of the shape "UNLESS the Write call
SUCCEEDS ... the navigator MUST stop blocked ..." was pinned on the consequent only;
the entire outcome-keying the remediation existed to introduce appeared in ZERO
patterns repo-wide, and rewriting the source back to the cause-keyed form left the
suite green. The remedy is NOT to swap to the antecedent alone. A pin carrying only
the condition leaves the obligation rewritable — for "if authentication fails, deny
access," rewriting `deny access` to `allow access` keeps a condition-only pin green.
That is the same defect mirrored, and it is no better.

Before finalizing a pattern, ask of EACH clause independently: if someone deleted or
inverted the part of the sentence that makes this rule THIS rule, would this pattern
stop matching? Ask it once of the condition and once of the obligation. Any clause
that answers "no" is unpinned, and you pinned the wrong clause — or too few of them.

When some part of a rule genuinely cannot be carried (a negation supplied by a `## Do
Not` heading rather than by the sentence, say), that is a residual, not a pass: name it
plainly in the fixture `description` per rule 1.

## 3. Consumers pin the reference; the canonical file pins the claim

**Invariant: a test must punish contract-breaking edits, not truthful wording
improvements — a suite that breaks on honest rewording is a design smell.**

Pinning remedy prose byte-for-byte across six consumers made every honest wording
improvement break the suite. The correct division of labor:

- At each CONSUMER, pin that the POINTER still exists and still names the canonical
  section — not the remedy prose itself.
- In the CANONICAL file, pin a small number of load-bearing claims, each with a
  recorded reason (in the fixture `description`) for why that specific clause is
  load-bearing.

## 4. Bite-proof by source mutation, both directions

**Invariant: a fixture that has never been observed to fail protects nothing — you
must prove the pin bites before shipping it.**

Mutating the fixture PATTERN proves only that the fixture is evaluated. Mutating the
SOURCE proves the sentence is protected. The required procedure, both directions:

1. Mutate the pinned source clause → run the suite → confirm red, capturing the
   exact failure text.
2. Revert → confirm green.

Pattern-mutation is a supplement, never sufficient alone.

## 5. Matching is whitespace-normalized

**Invariant: layout is not load-bearing — pin the semantically load-bearing clause
and ignore wrapping and indentation.**

All fixture matching (source `pattern`, consumer presence, frontmatter `absent`)
collapses every whitespace run to a single space on BOTH the file content and the
pattern (`normalize_ws` in `tools/policy_check.sh`). A pinned word sequence
therefore survives re-wrapping, re-indentation, and list reformatting.

Accepted residual, stated plainly: normalization can join text across list items or
table rows, so a pin may match a word sequence spanning two semantic units. This is
acceptable because pins claim word-sequence presence, never meaning (rule 1).

**Standing canary for this rule.** The trip-condition pattern in
`tests/policy/safety-transport-degradation-hard-stop.json` (the `UNLESS the Write
call to the fixed-literal transport path SUCCEEDS ...` pattern) is pinned against
source prose in `plugin/governance/security-policy.md` that is deliberately wrapped
across five lines instead of kept on one. This is not accidental formatting: it is a
live regression proof that matching stays whitespace-normalized. If `normalize_ws`
in `tools/policy_check.sh` ever regresses to raw substring matching, that fixture
fails immediately because the wrapped source no longer matches a single-line
pattern. Reflowing the sentence back onto one line — even as a pure tidy-up with no
wording change — removes the only standing proof of this rule and lets that
regression ship silently. Leave the wrapping as-is.

## 6. `set_check` applicability

**Invariant: enumerable membership where an ADDED member is the threat needs
`set_check` — it is the only primitive that catches an addition.**

Presence pins can only notice deletion. When the threat model includes someone
adding an unreviewed member (a grant, a denylist token, a marker line), use
`set_check` with `equal` or `subset` mode. Constraints and residuals:

- `files` is a LITERAL list with NO glob expansion. That is partial protection: it
  blocks removal and drift in the files it names, and it is blind to newly added
  files. Both halves are true — say both in the fixture `description`; the
  protection is worth having despite the blind half.
- `extract_regex` is LINE-SCOPED, so markers must be single-line by construction.
- The capture group MUST be a NEGATED-DELIMITER class anchored on a structural
  marker (e.g. `[^:<[:space:]]+`), NEVER a positive charset. A positive charset
  silently narrows what the assertion can EVER see: a real grant authored as
  `COMMIT-GRANT Overmind_2:` was invisible to `[a-z][a-z-]*` and `--strict` exited
  0 on a forged privilege line.

## 7. Presence-checks cannot find absence defects

**Invariant: a presence-detector can never find a body whose defect is that a
required clause is ABSENT.**

Presence-checks and required-clause-checks are DIFFERENT mechanisms; choosing one
leaves the other half open. If the failure mode you are guarding against is "this
file no longer says X," a presence pin covers it. If the failure mode is "a NEW
file (or a new section) fails to say X," no fixture in this directory can see it —
that requires a structural check in `tools/policy_check.sh` itself (compare the
CHECK-numbered guards). Do not paper over the gap with a presence pin; name the
uncovered half in the fixture `description` or add the structural check.
