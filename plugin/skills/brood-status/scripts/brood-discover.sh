#!/usr/bin/env bash
#
# brood-discover — deterministic brood-manifest discovery/enumeration for hivemind:brood-status
# (issue #185, ADR-0020). Extracts the discovery glob that was previously inline navigator-body
# prose in brood-status's SKILL.md (steps 1a–1c) into a committed, testable engine — the exact
# "inline navigator-body logic" ADR-0020 rejects.
#
# This is a BEHAVIOR-PRESERVING refactor: the sorted manifest-path list it emits is identical to
# the prior prose result (resolve current checkout root → glob brood-*/manifest.json → sort
# lexicographically). The navigator now RUNS this script and consumes its stdout, instead of
# performing the glob in agent reasoning.
#
# INPUT (positional, optional):
#   $1  TEST-ONLY override for the checkout root. Defaults to `git rev-parse --show-toplevel`
#       (the CURRENT checkout). This is the SAME anchor `spawn-brood.sh` writes against, so the
#       read side and the write side agree by construction. From the main checkout it equals the
#       main checkout root (top-level behavior unchanged); from a linked worktree it correctly
#       yields THAT worktree's root, so nested/child-spawned broods are visible at each hatchery
#       level (issue #182, supported by construction — same anchor at every level, no tree-walk).
#       The glob PATTERN is HARDCODED; no untrusted/caller-supplied path is interpolated beyond
#       this single root argument.
#
# OUTPUT (CONTRACT):
#   One ABSOLUTE manifest path per line on stdout, lexicographically sorted (= brood-id order,
#   since all ids share the `brood-` prefix). ZERO matches → ZERO lines, exit 0 — an empty glob
#   is SUCCESS (the navigator renders "No broods found." on zero lines), NOT an error.
#
# NOT THIS SCRIPT'S JOB:
#   - manifest CONTENTS validation (torn/garbage JSON) — that stays the projector's job
#     (`brood-status-project.sh` exit 2). A `brood-*` dir WITHOUT a `manifest.json` is naturally
#     skipped by the glob (no match) — correct, not an error.
#
# Conventions (ADR-0020 thin-entrypoint): `set -euo pipefail`, an EXIT trap ending in a
# guaranteed-zero `:`, NO `realpath`/`readlink` (BSD/macOS portability). No `_shared/containment.sh`
# is sourced: the root is ground truth (show-toplevel) and the pattern is hardcoded, so a plain
# `[ -d ]` check suffices — no containment guard is load-bearing here.

set -euo pipefail
trap ':' EXIT

# Resolve the checkout root: explicit test override, else git ground truth. `git rev-parse
# --show-toplevel` fails (nonzero, empty stdout) outside a git repo — propagate that as a clean
# blocker rather than globbing an empty root.
root="${1:-$(git rev-parse --show-toplevel)}"

if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "brood-discover: checkout root is empty or not a directory: '${root}'" >&2
    exit 1
fi

# Enumerate per-brood manifests. nullglob is MANDATORY: without it a no-match glob yields the
# literal pattern string (a real bug — the navigator would treat the pattern as a path). With it,
# zero matches expand to an empty array. The pattern is hardcoded; only "$root" is variable.
shopt -s nullglob
manifests=( "$root"/.hivemind/broods/brood-*/manifest.json )

# Zero matches → zero lines, exit 0 (empty is success — "No broods found." is the navigator's call).
if [ "${#manifests[@]}" -eq 0 ]; then
    exit 0
fi

# Positively validate the brood-id directory segment of each matched manifest before emitting it
# (issue #185, ADR-0019 floor-at-input). The navigator splices each emitted path into an
# LLM-authored Bash command (`bash brood-status-project.sh "<manifest_path>" …`); per repo doctrine
# (security-policy.md, ADR-0019) double-quoting does NOT neutralize `$(...)`, backticks, or `${}`
# when untrusted bytes sit in command SOURCE. A directory literally named
# `.hivemind/broods/brood-$(payload)/manifest.json` would otherwise let `$(payload)` execute in the
# coordinator session. spawn-brood.sh only ever creates `brood-<uuidv4>` dirs, so the brood-id
# segment is REQUIRED to match `^brood-[0-9a-fA-F-]+$` — the literal `brood-` prefix followed by hex
# digits and dashes only (the shape of `brood-<uuidv4>`). This admits every legitimate spawn-created
# dir and structurally excludes ALL shell metacharacters (`$ ( ) \` { } / ; & | > < space`), so an
# emitted path can carry no injection payload in its variable segment. Non-conforming dirs are
# illegitimate (never created by spawn-brood) and are SKIPPED silently. The segment is extracted as
# the basename of the dirname of the manifest path (the `brood-*` component immediately above
# `manifest.json`), not by fragile string-splitting that could mishandle a hostile name.
validated=()
for manifest in "${manifests[@]}"; do
    seg="$(basename "$(dirname "$manifest")")"
    if [[ "$seg" =~ ^brood-[0-9a-fA-F-]+$ ]]; then
        validated+=( "$manifest" )
    fi
done

# All matched dirs may be illegitimate → zero validated paths → zero lines, exit 0 (same empty-is-
# success contract as a zero-match glob).
if [ "${#validated[@]}" -eq 0 ]; then
    exit 0
fi

# Deterministic lexicographic order (= brood-id order). LC_ALL=C pins byte-order sorting
# independent of the caller's locale.
printf '%s\n' "${validated[@]}" | LC_ALL=C sort
