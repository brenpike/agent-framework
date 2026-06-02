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

# Deterministic lexicographic order (= brood-id order). LC_ALL=C pins byte-order sorting
# independent of the caller's locale.
printf '%s\n' "${manifests[@]}" | LC_ALL=C sort
