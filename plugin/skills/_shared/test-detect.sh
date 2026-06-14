# shellcheck shell=bash
#
# test-detect.sh — shared project test-command detector + `## Validation` recorder (seed-hive).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/test-detect.sh"`).
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
# SINGLE RESPONSIBILITY: detect the project's test command(s) from ROOT-LEVEL ecosystem signals
# (seed-hive SKILL.md step 14a/b) and assemble + record the `## Validation` section. This is the
# DETECT-ONLY contract: it NEVER runs, installs, or scaffolds a harness — each emitted command is
# a real, executable test command derived from an inspected signal, never fabricated. The
# `## Validation` APPEND itself is NOT re-implemented here: it DELEGATES to file-guard.sh's
# `hivemind_guard_validation_section` (P22 — one home for the append-if-absent section guard).
# This lib is DISTINCT from settings-merge.sh / claude-mem-path.sh (JSON merges) and from
# file-guard.sh (the plain-text append-if-absent family) — it is the ecosystem SIGNAL→COMMAND
# projector that FEEDS file-guard.sh's section guard.
#
# DEPENDENCY: jq (the package.json sub-signal parse) + coreutils + pure bash. The package.json
# parse runs INSIDE jq with the file content bound INERT via `--argfile`-free `< "$file"`-style
# stdin / inert program text — no dynamic value is ever spliced into the jq program source. For
# the `## Validation` append, this lib calls `hivemind_guard_validation_section`, which the
# SOURCING ENTRYPOINT must have sourced from file-guard.sh BEFORE invoking the recorder here
# (the test harness and the seed-hive entrypoint both source file-guard.sh alongside this lib).
#
# THE 9 ROOT-LEVEL ECOSYSTEM SIGNALS (mirror seed-hive/SKILL.md step 14a byte-for-byte; the
# ecosystem ORDER below is the canonical emission order for the monorepo multi-match case, where
# ALL matching root signals are recorded — one command per ecosystem, NEVER combined, NEVER
# scanning nested packages):
#   1. JS         — `package.json` present, with an ordered sub-signal cascade (see below) →
#                   `npm test` | `npx vitest run` | `npx jest`
#   2. Python     — `pyproject.toml` or `setup.py` carrying a pytest signal (a `pytest`
#                   dependency, a `[tool.pytest]` config, or `tests/` test files) → `pytest`
#   3. Go         — `go.mod` → `go test ./...`
#   4. Rust       — `Cargo.toml` → `cargo test`
#   5. .NET       — a `*.csproj` or `*.sln` referencing `Microsoft.NET.Test.Sdk` → `dotnet test`
#   6. Elixir     — `mix.exs` → `mix test`
#   7. Ruby       — `Gemfile` or `spec/` carrying an `rspec` signal → `bundle exec rspec`
#   8. Make       — `Makefile` with a real `test:` target → `make test`
#
# JS SUB-SIGNAL ORDERING (SKILL.md step 14a — emit at MOST ONE command for the JS ecosystem,
# choosing the FIRST sub-signal that matches in this order; vitest/jest are FALLBACKS that apply
# only when the `scripts.test` sub-signal is UNMATCHED, so a curated `npm test` is never bypassed
# by a parallel `npx vitest run` / `npx jest`):
#   1. `scripts.test` is a STRING that does NOT contain the case-insensitive substring
#      `Error: no test specified` → `npm test`. When the value DOES contain that substring (the
#      `npm`/`yarn`/`pnpm init` placeholder `echo "Error: no test specified" && exit 1`), this
#      sub-signal is treated UNMATCHED and falls through to 2–3. The substring match is
#      intentionally RUNNER-AGNOSTIC — it auto-covers all three init defaults with no per-runner
#      branch. A NON-STRING `scripts.test` (array, object, number) is likewise UNMATCHED and
#      falls through; a missing `scripts` object is already unmatched.
#   2. (only when 1 UNMATCHED) `package.json` declares a `vitest` dependency or config →
#      `npx vitest run`.
#   3. (only when 1–2 UNMATCHED) `package.json` declares a `jest` dependency or config → `npx jest`.
#   If none of 1–3 match, the JS ecosystem contributes NOTHING (the existing no-signal path then
#   applies if no other ecosystem matched either).
#
# NO-SIGNAL BEHAVIOR (SKILL.md step 14f): when NO ecosystem signal matches, the detector emits
# NOTHING — `hivemind_detect_test_commands` produces empty output and returns 0. The recorder
# `hivemind_record_validation` reports `none detected (recommend manual)` and writes NOTHING:
# nothing is fabricated, no harness invented. A documented-validation-only or non-executable repo
# (a Markdown plugin, a docs repo) is a legitimate outcome.
#
# DATA-BOUNDARY: every signal is read from disk as plain TEXT (file existence + content
# inspection) and every detected command is a FIXED string literal chosen by which signal fired —
# no signal CONTENT is ever interpolated into a command, an eval, a source, or a jq program. The
# package.json content enters jq only as parsed-document data via stdin; the jq program text is
# constant. Files are read with `jq` / `grep` / `[ -f ]` / `[ -d ]` only.
#
# OUTPUT CONTRACT (consumed by the seed-hive entrypoint, future step):
#   - hivemind_detect_test_commands <project_root>
#       Emits ZERO OR MORE detected commands on stdout, ONE per line, in the canonical ecosystem
#       order above (so monorepo multi-match is deterministic). Empty output ⇔ no signal. Always
#       returns 0. Pure detection: reads the project tree, writes nothing.
#   - hivemind_record_validation <project_root> <claude_md_file>
#       Runs the detector, and:
#         * NO command  → emits the status word `none detected (recommend manual)` on stdout,
#                         writes NOTHING (SKILL.md step 14f).
#         * >=1 command → assembles the `## Validation` section body (heading + one fenced
#                         ```bash block per detected command, in detector order) and DELEGATES
#                         the append-if-absent write to `hivemind_guard_validation_section`
#                         (file-guard.sh). Emits whatever that returns verbatim — `added` (the
#                         section was recorded) or `already documented` (a `## Validation`
#                         heading already existed; existing prose left byte-untouched, SKILL.md
#                         step 14c). Returns 0.
#       The status word is signalled IN-BAND on stdout (consistent with the rest of the family),
#       NOT via exit code, so the caller branches on the word.

# _hivemind_js_test_command <package_json_file>
# Emit the SINGLE JS-ecosystem command for <package_json_file> by walking the SKILL.md step-14a
# sub-signal cascade (curated scripts.test → vitest → jest), or emit NOTHING when none match.
# Pure: reads the file via jq only; writes nothing; the jq program text is constant and the file
# content enters as inert parsed-document data on stdin.
#
# INVARIANT: the placeholder rejection is a case-insensitive substring test for
# `Error: no test specified`, computed INSIDE jq against the parsed string value — runner-agnostic
# (covers `npm`/`yarn`/`pnpm init` with no per-runner branch). A non-string scripts.test value is
# treated as absent (the jq guard requires `type=="string"`).
_hivemind_js_test_command() {
  local pkg="$1"
  [ -f "$pkg" ] || return 0

  # Sub-signal 1: a curated, NON-placeholder string scripts.test → `npm test`.
  # The jq program is constant; the package.json enters as parsed-document data on stdin. The
  # placeholder check lowercases both sides so the substring match is case-insensitive, and
  # requires `type=="string"` so a non-string scripts.test (array/object/number) is UNMATCHED.
  local has_curated_test
  has_curated_test="$(jq -r '
    if (.scripts.test | type) == "string"
       and ((.scripts.test | ascii_downcase) | contains("error: no test specified") | not)
    then "yes" else "no" end
  ' "$pkg" 2>/dev/null)"
  if [ "$has_curated_test" = "yes" ]; then
    printf '%s\n' "npm test"
    return 0
  fi

  # Sub-signal 2 (only when 1 UNMATCHED): a vitest dependency or config → `npx vitest run`.
  # "dependency or config" = a `vitest` key anywhere in dependencies/devDependencies, OR a
  # top-level `vitest` config object in package.json.
  local has_vitest
  has_vitest="$(jq -r '
    if ((.dependencies // {}) | has("vitest"))
       or ((.devDependencies // {}) | has("vitest"))
       or (has("vitest"))
    then "yes" else "no" end
  ' "$pkg" 2>/dev/null)"
  if [ "$has_vitest" = "yes" ]; then
    printf '%s\n' "npx vitest run"
    return 0
  fi

  # Sub-signal 3 (only when 1-2 UNMATCHED): a jest dependency or config → `npx jest`.
  local has_jest
  has_jest="$(jq -r '
    if ((.dependencies // {}) | has("jest"))
       or ((.devDependencies // {}) | has("jest"))
       or (has("jest"))
    then "yes" else "no" end
  ' "$pkg" 2>/dev/null)"
  if [ "$has_jest" = "yes" ]; then
    printf '%s\n' "npx jest"
    return 0
  fi

  return 0
}

# _hivemind_python_has_pytest_signal <project_root>
# Return 0 when a pytest signal exists per SKILL.md step 14a: a `pytest` dependency or
# `[tool.pytest]` config in pyproject.toml/setup.py, OR `tests/` test files. The ecosystem gate
# (pyproject.toml OR setup.py present) is checked by the caller; this helper confirms the SIGNAL.
_hivemind_python_has_pytest_signal() {
  local root="$1"
  if [ -f "$root/pyproject.toml" ]; then
    grep -qi 'pytest\|\[tool\.pytest' "$root/pyproject.toml" 2>/dev/null && return 0
  fi
  if [ -f "$root/setup.py" ]; then
    grep -qi 'pytest' "$root/setup.py" 2>/dev/null && return 0
  fi
  # `tests/` test files: a tests/ directory holding at least one test_*.py / *_test.py file.
  if [ -d "$root/tests" ]; then
    if ls "$root"/tests/test_*.py "$root"/tests/*_test.py >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# _hivemind_dotnet_has_test_sdk <project_root>
# Return 0 when a root-level `*.csproj` or `*.sln` references `Microsoft.NET.Test.Sdk` (SKILL.md
# step 14a). File existence ALONE is insufficient — the actual reference must be present.
_hivemind_dotnet_has_test_sdk() {
  local root="$1" f
  for f in "$root"/*.csproj "$root"/*.sln; do
    [ -f "$f" ] || continue
    grep -q 'Microsoft\.NET\.Test\.Sdk' "$f" 2>/dev/null && return 0
  done
  return 1
}

# _hivemind_ruby_has_rspec_signal <project_root>
# Return 0 when an rspec signal exists per SKILL.md step 14a: a Gemfile referencing `rspec`, OR a
# `spec/` directory holding at least one `*_spec.rb` file.
_hivemind_ruby_has_rspec_signal() {
  local root="$1"
  if [ -f "$root/Gemfile" ]; then
    grep -qi 'rspec' "$root/Gemfile" 2>/dev/null && return 0
  fi
  if [ -d "$root/spec" ]; then
    if ls "$root"/spec/*_spec.rb >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# _hivemind_makefile_has_test_target <makefile>
# Return 0 when <makefile> declares a REAL `test:` target (a line whose first non-whitespace token
# is `test` immediately followed by `:`), per SKILL.md step 14a "a real test: target". Mere file
# existence is insufficient.
_hivemind_makefile_has_test_target() {
  local makefile="$1"
  [ -f "$makefile" ] || return 1
  grep -Eq '^test[[:space:]]*:' "$makefile" 2>/dev/null
}

# hivemind_detect_test_commands <project_root>
# Emit ZERO OR MORE detected test commands on stdout, ONE per line, in the canonical ecosystem
# order (JS, Python, Go, Rust, .NET, Elixir, Ruby, Make). Each emitted command is a real,
# executable test command derived from an INSPECTED root-level signal — never fabricated, never
# the result of merely a file existing. Empty output ⇔ no signal matched (SKILL.md step 14f).
#
# MONOREPO MULTI-MATCH (SKILL.md step 14b): when more than one ROOT-LEVEL ecosystem signal
# matches, ALL detected commands are emitted — one per ecosystem, in the order above — NEVER
# combined into a single runner, NEVER one-command-per-nested-package (only root/workspace-root
# signals are inspected). Always returns 0.
#
# ARGUMENTS
#   <project_root>  absolute path to the repo root whose ROOT-LEVEL signals are inspected.
hivemind_detect_test_commands() {
  local root="$1"

  # 1. JS — package.json present → walk the curated/vitest/jest sub-signal cascade.
  if [ -f "$root/package.json" ]; then
    _hivemind_js_test_command "$root/package.json"
  fi

  # 2. Python — pyproject.toml or setup.py carrying a pytest signal.
  if [ -f "$root/pyproject.toml" ] || [ -f "$root/setup.py" ]; then
    if _hivemind_python_has_pytest_signal "$root"; then
      printf '%s\n' "pytest"
    fi
  fi

  # 3. Go — go.mod.
  if [ -f "$root/go.mod" ]; then
    printf '%s\n' "go test ./..."
  fi

  # 4. Rust — Cargo.toml.
  if [ -f "$root/Cargo.toml" ]; then
    printf '%s\n' "cargo test"
  fi

  # 5. .NET — *.csproj or *.sln referencing Microsoft.NET.Test.Sdk.
  if _hivemind_dotnet_has_test_sdk "$root"; then
    printf '%s\n' "dotnet test"
  fi

  # 6. Elixir — mix.exs.
  if [ -f "$root/mix.exs" ]; then
    printf '%s\n' "mix test"
  fi

  # 7. Ruby — Gemfile or spec/ carrying an rspec signal.
  if _hivemind_ruby_has_rspec_signal "$root"; then
    printf '%s\n' "bundle exec rspec"
  fi

  # 8. Make — Makefile with a real test: target.
  if _hivemind_makefile_has_test_target "$root/Makefile"; then
    printf '%s\n' "make test"
  fi

  return 0
}

# _hivemind_validation_section_body <command...>
# Assemble the `## Validation` section body from the detected command(s): the `## Validation`
# heading, then one fenced ```bash block per command IN ORDER (SKILL.md step 14d: "a fenced code
# block (or a list of fenced blocks when multiple)"). The body BEGINS with the `## Validation`
# heading line so file-guard.sh's section presence predicate and the appended content agree.
# Pure: emits the body on stdout; no side effects. At least one command is required.
_hivemind_validation_section_body() {
  printf '## Validation\n'
  local cmd
  for cmd in "$@"; do
    printf '\n```bash\n%s\n```\n' "$cmd"
  done
}

# hivemind_record_validation <project_root> <claude_md_file>
# Detect the project's test command(s) and record them under `## Validation` in <claude_md_file>,
# DELEGATING the append-if-absent write to file-guard.sh's `hivemind_guard_validation_section`
# (P22 — this lib never re-implements the section append). Behavior (SKILL.md step 14c-f):
#   * NO command detected → emit `none detected (recommend manual)` and write NOTHING.
#   * >=1 command        → assemble the section body and call hivemind_guard_validation_section,
#                          emitting its result verbatim (`added` | `already documented`).
# The status word is emitted IN-BAND on stdout; returns 0.
#
# PRECONDITION: the SOURCING entrypoint MUST have sourced file-guard.sh (so
# `hivemind_guard_validation_section` is defined) before calling this function. The seed-hive
# entrypoint and the test harness both source file-guard.sh alongside this lib.
#
# ARGUMENTS
#   <project_root>    absolute path to the repo root whose signals drive detection.
#   <claude_md_file>  absolute path to repo-root CLAUDE.md (created-if-absent by the guard).
hivemind_record_validation() {
  local root="$1" claude_md="$2"

  local commands=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && commands+=("$line")
  done < <(hivemind_detect_test_commands "$root")

  if [ "${#commands[@]}" -eq 0 ]; then
    printf '%s\n' "none detected (recommend manual)"
    return 0
  fi

  local body
  body="$(_hivemind_validation_section_body "${commands[@]}")"
  # DELEGATE the append-if-absent section write to file-guard.sh (P22). Its return word
  # (`added` | `already documented`) is the recorder's status verbatim.
  hivemind_guard_validation_section "$claude_md" "$body"
}
