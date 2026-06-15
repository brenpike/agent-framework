# shellcheck shell=bash
#
# json-normalize.sh — shared JSON wrong-typed-container normalization primitive (seed-hive).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/json-normalize.sh"`).
# It defines functions only; it runs no top-level statements and changes no caller state
# beyond defining the functions below. `bash -n` validates it as a sourced fragment.
#
# P18 FLOOR EXCEPTION (ADR-0020): as a SOURCED library this file deliberately
# OMITS the P18 shell-safety floor `set -e` / `set -o pipefail` and any EXIT trap. A sourced
# file mutates the SOURCING shell's option state, so installing those here would corrupt
# every caller's shell; the floor is therefore the documented exception, not the full
# `set -euo pipefail`. This file carries no top-level `set` at all (pure function
# definitions); each caller owns its own `set -u` and error routing. Allowlisted under
# CHECK13 as a P18 documented exception.
#
# SINGLE RESPONSIBILITY: be the ONE home for the JSON wrong-typed-container normalization
# primitive (P22, rule-of-three). A settings-shaped JSON document carries keys whose CONTRACT
# type is a container: object-typed keys (enabledPlugins / pluginConfigs / hooks / permissions)
# and array-typed keys (permissions.allow). A merge that runs add-if-absent over such a key must
# first NORMALIZE the existing value's SHAPE: a missing/null/string/number/bool/array value at an
# object-typed key, or a non-array at an array-typed key, is NOT a preservable user value — it is
# the canonical ABSENT-needing-seed state and must collapse to the empty container of the contract
# type BEFORE any predicate runs. This file supplies that normalization as jq DEFINITION TEXT only;
# it performs NO I/O, resolves no path, and reads no input.
#
# PRIMITIVE SHAPE: this file exposes the primitive as a jq DEFINITION emitted as an inert STRING
# (program text). A consumer splices the returned def block into its OWN single jq program and
# then applies `canon_obj(<path-expr>)` / `canon_arr(<path-expr>)` against its own parsed,
# `--argjson`-bound document. Emitting program TEXT (not running jq) keeps this file a pure,
# I/O-free primitive home: it normalizes the SHAPE language once, and every consumer normalizes
# at its own chokepoint with one shared definition.
#
# DATA-BOUNDARY (MANDATORY — program-text-only, NO value splice): the function below emits ONLY
# FIXED jq PROGRAM TEXT (the definitions). It interpolates NO runtime, dynamic, or untrusted value
# into that text — there is nothing to interpolate, the def block is a constant. The CONSUMER binds
# every actual value (the settings document and any toggle) into ITS jq program via its own
# `--argjson` / `--arg` bindings; THIS lib supplies only the def text. No untrusted byte ever
# reaches a jq program through this file.
#
# DOCUMENTED INVARIANT (canon_obj / canon_arr never clobber a real user value): coercing a
# wrong-typed container to the empty container NEVER discards a preservable user value. A non-object
# sitting at an object-typed settings key (e.g. a string or array at `enabledPlugins`) holds no
# object entries to preserve; a non-array at an array-typed key (e.g. a string at
# `permissions.allow`) holds no array elements to preserve. Collapsing it to `{}` / `[]` yields the
# canonical empty container the consumer's add-if-absent seed then widens — the seed ADDS keys/
# elements and removes none, so nothing a user could have meant to keep is lost. A correctly-typed
# container is returned UNTOUCHED (its existing entries are preserved verbatim).
#
# DEPENDENCY: jq only (the emitted text is a jq program fragment). This file itself runs no jq.

# hivemind_jq_canon_defs
# Echo the shared jq DEFINITION block (program text) for the two container-normalization helpers.
# Pure: no side effects, no exit, reads no input, interpolates no value — emits a constant string.
#
# The emitted defs:
#   def canon_obj(f): (f) as $v | if ($v|type)=="object" then $v else {} end;
#       Return the value of path-expr `f` when it is a correctly-typed OBJECT, else `{}`. Covers
#       missing/null/string/array/number/bool at an object-typed key → canonical empty object.
#   def canon_arr(f): (f) as $v | if ($v|type)=="array"  then $v else [] end;
#       Return the value of path-expr `f` when it is a correctly-typed ARRAY, else `[]`. Covers
#       missing/null/string/object/number/bool at an array-typed key → canonical empty array.
#
# A consumer splices this block at the top of its single jq program and then uses
# `canon_obj(.enabledPlugins)`, `canon_arr(.permissions.allow)`, etc. against its own document.
hivemind_jq_canon_defs() {
  cat <<'CANON_DEFS'
def canon_obj(f): (f) as $v | if ($v|type)=="object" then $v else {} end;
def canon_arr(f): (f) as $v | if ($v|type)=="array" then $v else [] end;
CANON_DEFS
}
