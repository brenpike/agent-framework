# shellcheck shell=bash
#
# settings-merge.sh — shared `.claude/settings.json` required-key merge core (seed-hive).
#
# THIS FILE IS SOURCED, NOT EXECUTED. No shebang: each caller sources it by absolute
# path derived from its OWN script_dir (`. "$plugin_root/skills/_shared/settings-merge.sh"`).
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
# SINGLE RESPONSIBILITY: merge the hivemind required keys into a `.claude/settings.json`
# object with PRESERVE-EXISTING semantics, detect the `agent` conflict, and union-append the
# frozen `permissions.allow` template. This file is PURE MERGE: it does not read or write any
# file, resolve the project root, perform companion detection, touch `.gitignore` / `.envrc` /
# hooks, or invoke any skill — the entrypoint owns all of that. The settings JSON enters and
# leaves as a string; the caller does the I/O.
#
# SINGLE-SOURCE FROZEN TEMPLATE (P1): the recommended least-privilege `permissions.allow`
# template lives in EXACTLY ONE place — `hivemind_settings_permissions_template` below — as
# DATA. seed-hive/SKILL.md holds NO mirror of the rule list — it points here as the single
# source. No other site re-states the rule list; a caller that needs the template calls the
# function. The rule ORDER is load-bearing (the create-from-absent path emits the array in
# template order); do not reorder, drop, or reword an entry. New rules APPEND at the END.
#
# DATA-BOUNDARY: every dynamic value (the existing settings JSON, the agent target, each
# template rule) enters jq as an inert `--arg` / `--argjson` binding, NEVER interpolated into
# the jq program source. The settings JSON is parsed once via `--argjson` so jq validates it;
# malformed input is reported, never partially merged.
#
# MERGE INVARIANTS (mirror seed-hive/SKILL.md step 6 + Merge Rules, byte-preserving):
#   - PRESERVE-EXISTING: every key the caller already had that is not a required key is kept
#     untouched, in place. A required key already at the correct value is `already present`,
#     not re-added.
#   - enabledPlugins["hivemind@brenpike"] = true — add-if-absent; idempotent. VALUE-EQUALITY
#     classification: `already present` IFF the existing value already EQUALS the canonical
#     target (== true). The build unconditionally writes `true`, so a key present-but-false /
#     null / wrong-typed is NOT already present — it is reported `added` (corrected), matching
#     the write. An absent key is `added`; a key already `== true` is `already present`.
#   - enabledPlugins["caveman@caveman"] / ["claude-mem@thedotmack"] / ["codex@openai-codex"]
#     = true — written ONLY when the matching companion flag resolves yes; add-if-absent. Same
#     VALUE-EQUALITY classification (== true) once resolved yes; the `resolved no` short-circuit
#     (companion not resolved-yes) is checked FIRST, before the value test.
#   - agent = "<agent_target>" — add-if-absent. VALUE-STATE NORMALIZATION (ABSENT detection): an
#     existing `agent` that is missing, `null`, or a string that is EMPTY or WHITESPACE-ONLY ("",
#     " ", "\t") normalizes to ABSENT → classified `added` and the target is written. An empty /
#     whitespace agent is NOT a real conflicting value; it never blocks. A present NON-STRING value
#     (number/bool/object/array) is a real wrong-type value the user set and stays in the conflict
#     branch (NOT normalized to absent). CONFLICT DETECTION: if `agent` already holds a real
#     non-empty value DIFFERENT from the target, behavior is GATED by the 7th arg
#     <agent_conflict_approved>:
#       * approved != "yes" (default): the merge does NOT overwrite; it flags `agent_conflict`
#         with the existing value, returns `status: conflict`, and keeps the existing `agent`
#         byte-unchanged so the caller can stop blocked and seek user approval (SKILL.md Merge
#         Rules: "stop blocked and report the conflict. Do not overwrite without explicit user
#         approval").
#       * approved == "yes": the merge OVERWRITES `.settings.agent` to the target, classifies it
#         `overwritten`, returns `status: ok`, and `agent_conflict` is null. This restores the
#         base-prose contract: overwrite is permitted ONLY WITH explicit user approval.
#     NEVER-SILENTLY-OVERWRITE INVARIANT PRESERVED: an overwrite happens ONLY when the caller
#     passes approved=="yes", a flag the navigator sets ONLY after obtaining user approval. With
#     the flag absent/any-other-value the never-overwrite-on-conflict behavior is byte-identical
#     to the no-approval path. The approval gate is the conflict branch ONLY; an absent or
#     already-equal `agent` makes approval inert (normal add / already-present classification).
#   - pluginConfigs["caveman@caveman"].options.defaultLevel = "ultra" — caveman=yes only,
#     NESTED-LEAF add/correct on the SPECIFIC .options.defaultLevel leaf, NOT on the presence of
#     the parent "caveman@caveman" key. A parent config object that already exists but LACKS
#     defaultLevel (or holds a non-"ultra" value) is NOT configured for ultra mode: the leaf is
#     set to "ultra" while every sibling key in the config object and in .options is PRESERVED.
#     `already present` requires defaultLevel to ALREADY equal "ultra". Each container on the path
#     (config object, .options) is canon_obj-normalized so a wrong-typed nested container collapses
#     to {} before the leaf is set — a malformed nested config never crashes or clobbers.
#   - hooks.SubagentStart — the caveman ultra-mode hook entry (caveman=yes only), add-if-absent
#     on the SPECIFIC `.claude/hooks/caveman-ultra-subagent.sh` command, NOT on the presence of
#     the SubagentStart key. An existing unrelated SubagentStart array is PRESERVED and the
#     caveman entry is appended to it; `already present` requires that exact command be wired.
#   - permissions.allow — union/append-if-absent of the frozen template (seed_allowlist=yes):
#     keep every existing entry in its original order, then append each template rule whose
#     exact string is NOT already present. NEVER overwrite, remove, dedupe, or reorder existing
#     entries. Absent `permissions.allow` → created containing only the template rules in
#     template order. `permissions` present without `allow` → `allow` added, sibling permissions
#     keys preserved. seed_allowlist=no → `permissions.allow` left untouched.
#   - IDEMPOTENT + BYTE-STABLE: re-merging an already-seeded settings object is a no-op — every
#     key reports `already present`, and the emitted `.settings` equals the input (modulo jq's
#     canonical key ordering, which is stable across re-runs).
#   - SHAPE-NORMALIZE-AT-ONE-CHOKEPOINT: every container-typed key (object-typed enabledPlugins /
#     pluginConfigs / hooks / permissions, array-typed permissions.allow) is normalized via the
#     shared canon_obj/canon_arr defs (sourced from json-normalize.sh, spliced as program text)
#     BEFORE any predicate (has() / index() / membership) or build assignment runs. A WRONG-TYPED
#     existing container is the canonical absent/needs-seed state: it collapses to {} / [] (it held
#     no contract-type entries to preserve), and the required seed is then add-if-absent over that
#     empty — so a malformed container NEVER aborts the jq program (no crash → no empty `.status` →
#     no seed abort) and NEVER clobbers a real value. ONE normalizer routes every container site,
#     classification AND build (so the report and the written settings share one canonical shape);
#     there is no per-key type branch. A CORRECTLY-typed container is returned untouched, so
#     correctly-typed inputs are byte-identical to the pre-normalization behavior. This guard is
#     NESTED-only: the top-level non-object pre-check (status "malformed") still runs first.
#
# MALFORMED / EMPTY INPUT (SKILL.md step 4: "otherwise treat existing settings as {}"):
#   an EMPTY settings string is treated as `{}` (the absent-file case the caller passes through).
#   A NON-EMPTY but UNPARSEABLE settings string is NOT silently coerced to `{}` — that would
#   erase a user's real-but-torn file. It is reported via `status: "malformed"` and the caller
#   fails closed; no merge is performed.
#
# OUTPUT CONTRACT (consumed by the seed-hive entrypoint, future step):
#   hivemind_settings_merge emits ONE JSON object on stdout (exit 0 on a produced result; the
#   conflict and malformed cases are signalled IN-BAND in that object's `status`, not via exit
#   code, so the caller branches on `status`). Shape:
#     {
#       "status": "ok" | "conflict" | "malformed",
#       "settings": <merged settings object>,   // on malformed: the input is NOT echoed; null
#       "agent_conflict": null | { "existing": <str>, "required": <str> },  // null when overwritten
#       "keys": {                                // classification per required key
#         "enabledPlugins.hivemind@brenpike": "added" | "already present",
#           // VALUE-EQUALITY: "already present" IFF the value is ALREADY == true; a
#           // present-but-false/null/wrong-typed key is "added" (the build corrects it to true).
#         "agent": "added" | "already present" | "unchanged" | "conflict" | "overwritten",
#         "enabledPlugins.caveman@caveman": "added" | "already present" | "resolved no",
#         "enabledPlugins.claude-mem@thedotmack": "...",
#         "enabledPlugins.codex@openai-codex": "...",
#         "pluginConfigs.caveman@caveman": "added" | "already present" | "resolved no",
#           // NESTED-LEAF: "already present" ONLY when .options.defaultLevel is ALREADY
#           // "ultra"; "added" when the leaf had to be set or corrected (parent absent, OR
#           // parent present but defaultLevel missing / != "ultra"); "resolved no" when caveman != yes.
#         "hooks.SubagentStart": "added" | "already present" | "resolved no"
#       },
#       "permissions_allow": [                   // one entry per template rule, in template
#         { "rule": <str>, "result": "added" | "already present" },   // order; [] when
#         ...                                                          // seed_allowlist=no
#       ]
#     }
#   `agent` classification: `added` (was absent — key missing/null, OR an empty/whitespace-only
#   string, which normalizes to ABSENT and the target is written), `already present`/`unchanged`
#   (already equal to the target — both map here; SKILL.md output allows either token), `conflict`
#   (a real non-empty value, OR a present non-string value, differing from the target AND not
#   approved; the conflict block is populated and `.settings.agent` is the existing value),
#   `overwritten` (differing real value AND approved=="yes"; `.settings.agent` is the target and
#   the conflict block is null).
#
# DEPENDENCY: jq only (POSIX + jq). No yq, no sed/awk.
#
# SHAPE-NORMALIZATION AT ONE CHOKEPOINT (P22 / canon_obj+canon_arr): every container-typed key the
# merge reads (the object-typed enabledPlugins / pluginConfigs / hooks / permissions, and the
# array-typed permissions.allow) is normalized to its canonical empty container BEFORE any predicate
# runs. A WRONG-TYPED existing container (e.g. enabledPlugins as an array/string, permissions.allow as
# a string) is NOT a preservable user value — it holds no entries of the contract type — so it
# collapses to {} / [] via the shared canon_obj/canon_arr defs (sourced from json-normalize.sh and
# spliced as fixed PROGRAM TEXT at the top of the single jq program). The required seed is then
# add-if-absent over that canonical empty: the merge returns status "ok" (NEVER crashes the jq program
# and NEVER clobbers a real value), because a malformed container held no real entry to preserve. ONE
# normalizer routes every container site (classification AND build) — no per-key type branch. The
# top-level non-object pre-check (status "malformed") still runs FIRST; only NESTED container keys are
# shape-normalized here. A CORRECTLY-typed container is returned untouched, so correctly-typed inputs
# are byte-identical to before.

# ── self-location + sibling-lib source (SOURCE-OR-DIE) ──────────────────────────
# THIS file is itself a SOURCED lib (no shebang); BASH_SOURCE[0] still resolves to this file's own
# path when sourced, so we self-locate the _shared dir from it (never a caller value) and source the
# json-normalize.sh sibling that supplies the canon_obj/canon_arr def text. SOURCE-OR-DIE: a missing
# or unparseable sibling returns non-zero from this fragment so the caller (entrypoint loop / test
# harness) fails closed exactly as it does for this file — the merge cannot run its shape guard
# without those defs. Re-sourcing is idempotent (it only redefines a pure echo function).
__settings_merge_shared_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$__settings_merge_shared_dir/json-normalize.sh"
unset __settings_merge_shared_dir

# hivemind_settings_permissions_template
# Emit the frozen least-privilege `permissions.allow` template, ONE rule per line, in the
# canonical (load-bearing) order. This is the SINGLE DATA source for the template (P1); the
# merge function reads it through this function, and any caller that needs to display or test
# the template uses it too. Pure: no side effects, no exit, reads no input.
#
# INVARIANT: this list is the SINGLE source of the frozen template — no mirror exists in
# seed-hive/SKILL.md. The order is canonical and load-bearing (absent-array creation emits in
# this order). Do not reorder, drop, or reword an entry; add new rules at the END only, since
# the merge is union append-if-absent and never reorders an existing consumer's array.
#
# INVARIANT (REACH): a rule appended here reaches an ALREADY-SEEDED consumer ONLY when
# `hivemind:seed-hive` is re-run against that project. This template is merged into a consumer's
# `.claude/settings.json` at seed time and at NO other time — a plugin upgrade alone delivers
# NOTHING, because upgrading never re-merges settings. Adding a rule here is therefore only half
# a fix; the consumer-facing half is telling upgraders to re-seed (the upgrade-path bullet under
# `## When to Use` in seed-hive/SKILL.md). The merge is idempotent append-if-absent, so the
# re-seed is always safe and preserves existing entries. See issue #323.
#
# ONE-TIME DROP: the former `Bash(node /path/to/.claude/plugins/cache/openai-codex/codex/*)` entry
# was deleted from this template. `/path/to/` is a DOCUMENTATION PLACEHOLDER that had been frozen
# into runtime data, and this heredoc is single-quoted, so nothing ever expanded it — the rule
# shipped verbatim and matched NO real path on ANY machine. It was therefore unmatchable as
# shipped, so nothing could ever have depended on it. The drop also mutates NO existing consumer
# file: the merge is union append-if-absent and NEVER removes, so dropping the entry only stops
# new seeds and re-seeds from adding it. An ALREADY-SEEDED consumer keeps the dead entry until a
# human deletes it by hand. Automatic removal is DELIBERATELY NOT IMPLEMENTED — it would break the
# never-remove invariant above, and it could delete a rule a user had already repaired to point at
# their real `$HOME` cache path.
#
# INVARIANT (NO-PROVIDER-GRANT): no local-review provider grant — codex today, or copilot or
# any future provider — may be added to this template. Three reasons:
#   1. This template merges into a COMMITTED, team-shared `.claude/settings.json`, so a
#      machine-specific `$HOME` cache path is wrong-by-construction for everyone but the seeder.
#   2. The provider invocation is already PRE-APPROVED provider-agnostically and
#      `$HOME`-independently by the `hivemind:adaptation-cycle` skill's frontmatter
#      `allowed-tools` (today `Bash(node *)`, which covers the codex invocation; a future
#      provider's binary grant, e.g. `Bash(copilot *)`, belongs in that same frontmatter list —
#      never here). Per ADR-0010's 2026-07-27 amendment, `allowed-tools` PRE-APPROVES a permission
#      but never PROVISIONS a tool.
#   3. Per-contributor grants belong in the GITIGNORED `.claude/settings.local.json`, which is
#      exactly what `.devcontainer/postCreate.sh` already does.
hivemind_settings_permissions_template() {
  cat <<'TEMPLATE'
Bash(echo *)
Bash(printf *)
Bash(cat *)
Bash(grep *)
Bash(jq *)
Bash(head *)
Bash(tail *)
Bash(ls *)
Bash(wc *)
Bash(sort *)
Bash(uniq *)
Bash(git ls-files *)
Bash(git ls-tree *)
Bash(git grep *)
Bash(git tag)
Bash(git tag -l*)
Bash(git tag --list*)
Bash(git stash list)
Bash(git stash show *)
Edit(.hivemind/review-loop/*)
Edit(.hivemind/runs/.init-inputs-*.json)
Edit(.hivemind/runs/.record-inputs-*.json)
Edit(.hivemind/runs/.markfb-inputs-*.json)
Edit(.hivemind/spawn-inputs.*.json)
Edit(.hivemind/seed-inputs-*.json)
TEMPLATE
}

# hivemind_settings_merge <settings_json> <agent_target> <caveman_yes> <claude_mem_yes> \
#                         <codex_yes> <seed_allowlist_yes> [<agent_conflict_approved>]
#
# Merge the hivemind required keys into <settings_json> per the MERGE INVARIANTS in the header
# and emit the OUTPUT CONTRACT JSON object on stdout. The first six arguments are required; the
# 7th (<agent_conflict_approved>) is optional and defaults to "no" so existing 6-arg callers are
# byte-unchanged.
#
# ARGUMENTS
#   <settings_json>     the current `.claude/settings.json` contents as a string. EMPTY → treated
#                       as `{}` (absent-file case). Non-empty unparseable → status "malformed".
#   <agent_target>      the required `agent` value, e.g. "hivemind:overlord". Enters jq as --arg.
#   <caveman_yes>       "yes" → write the caveman enabledPlugins/pluginConfigs/hook keys; any
#                       other value → those keys are skipped (classified "resolved no").
#   <claude_mem_yes>    "yes" → write enabledPlugins["claude-mem@thedotmack"]; else "resolved no".
#   <codex_yes>         "yes" → write enabledPlugins["codex@openai-codex"]; else "resolved no".
#   <seed_allowlist_yes>"yes" → union-append the frozen permissions.allow template; any other
#                       value → permissions.allow left untouched, permissions_allow = [].
#   <agent_conflict_approved>  OPTIONAL (default "no"). "yes" → authorize an `agent` OVERWRITE on
#                       the conflict branch (existing differs from target): write the target,
#                       classify `overwritten`, status "ok", no conflict block. Any other value /
#                       absent → never overwrite on conflict (status "conflict", agent unchanged).
#                       Inert when `agent` is absent or already equal to the target. Evaluated
#                       ONLY AFTER the malformed-settings fail-closed check: a non-empty
#                       unparseable blob with approved=="yes" STILL returns status "malformed" —
#                       approval authorizes an agent overwrite, NEVER clobbering a torn file.
#
# The settings JSON enters jq as --argjson (jq validates it); the agent target and each toggle
# enter as --arg; the template enters as --argjson (a JSON array built from the single DATA
# source). No dynamic value is ever spliced into the jq program text. The whole classification
# and merge run INSIDE one jq program so the verdict is computed against the parsed document,
# never against post-extraction bash strings.
hivemind_settings_merge() {
  local settings_json="$1"
  local agent_target="$2"
  local caveman_yes="$3"
  local claude_mem_yes="$4"
  local codex_yes="$5"
  local seed_allowlist_yes="$6"
  # OPTIONAL 7th arg: authorize an agent overwrite on the conflict branch. Default "no" so
  # existing 6-arg callers are byte-unchanged. This is a controlled "yes"/"no" string bound
  # inertly into jq as --arg below — it is NEVER spliced into jq program source.
  local agent_conflict_approved="${7:-no}"

  # EMPTY input is the absent-file case (SKILL.md step 4): treat as {}. A NON-EMPTY but
  # invalid input is NOT coerced — report malformed so the caller fails closed rather than
  # silently erasing a torn real file. "Invalid" covers: unparseable JSON, valid JSON that is
  # not an object (a settings file must be an object), AND a multi-document stream (two or more
  # concatenated top-level documents). The bare `jq -e 'type=="object"'` precheck accepted
  # multi-doc streams because jq streams them and exits 0 on the last document; the downstream
  # `--argjson settings` then rejected the stream and crashed. hivemind_jq_is_single_object_stdin
  # (STEP-001, json-normalize.sh) slurps into an array and requires length==1 AND type==object,
  # closing the multi-doc case while subsuming the old type check.
  if [ -z "$settings_json" ]; then
    settings_json='{}'
  elif ! printf '%s' "$settings_json" | hivemind_jq_is_single_object_stdin; then
    # Multi-document stream, unparseable JSON, or valid JSON that is not an object.
    jq -n '{status:"malformed", settings:null, agent_conflict:null, keys:{}, permissions_allow:[]}'
    return 0
  fi

  # Build the template as a JSON array from the SINGLE DATA source, passed inert via --argjson.
  local template_json
  template_json="$(hivemind_settings_permissions_template | jq -R . | jq -s .)"

  # Capture the shared container-normalization defs as PROGRAM TEXT (a constant def block; no
  # runtime value is interpolated). Spliced verbatim at the TOP of the single jq program below so
  # canon_obj/canon_arr are in scope before any predicate uses them. DATA-BOUNDARY preserved: this
  # is jq source text only — every runtime value still enters via --argjson/--arg.
  local canon_defs
  canon_defs="$(hivemind_jq_canon_defs)"

  # Single jq program: classify every required key against the PARSED input, then build the
  # merged settings with preserve-existing semantics. Toggles and the agent target are inert
  # --arg bindings; the template and parsed settings are inert --argjson bindings.
  jq -n \
    --argjson settings "$settings_json" \
    --arg agent "$agent_target" \
    --arg caveman "$caveman_yes" \
    --arg claude_mem "$claude_mem_yes" \
    --arg codex "$codex_yes" \
    --arg seed_allow "$seed_allowlist_yes" \
    --arg agent_approved "$agent_conflict_approved" \
    --argjson template "$template_json" '
    # ── shared container-shape normalizers (spliced PROGRAM TEXT from json-normalize.sh) ──
    # canon_obj(f) → f when f is an object, else {}; canon_arr(f) → f when an array, else [].
    # These collapse a wrong-typed container to its canonical empty BEFORE any predicate runs.
    '"$canon_defs"'
    # ── helpers ──────────────────────────────────────────────────────────────────
    # getpath-safe presence test for a nested key, run over the SHAPE-normalized enabledPlugins
    # object so a wrong-typed enabledPlugins (array/string/etc.) collapses to {} instead of
    # aborting has() — an absent enabledPlugins then classifies every companion as "added".
    def has_enabled($k): canon_obj($settings.enabledPlugins) | has($k);

    # VALUE-EQUALITY presence test for an enabledPlugins entry, run over the SHAPE-normalized
    # enabledPlugins object: true IFF the existing value already EQUALS the canonical target (true).
    # The build unconditionally writes `true`, so a key present-but-false/null/wrong-typed needs
    # correcting and must classify "added", NOT "already present" — this is value-not-presence.
    def enabled_true($k): canon_obj($settings.enabledPlugins) | (.[$k] == true);

    # The caveman SubagentStart hook entry, mirroring SKILL.md step 10d structure.
    # Every container-typed key is normalized at binding time so a wrong-typed existing value
    # collapses to its canonical empty container ({} / []) here, once, for both classification and
    # build. permissions.allow normalizes its parent object first, then the allow array.
    ($settings) as $s
    | canon_obj($s.enabledPlugins) as $ep
    | canon_obj($s.permissions) as $perm
    | (canon_arr($perm.allow)) as $existing_allow

    # ── agent value-state normalization (ABSENT / PRESENT-CANONICAL / PRESENT-MALFORMED) ──
    # An existing `agent` is ABSENT when the key is missing/null OR is a string that is empty or
    # whitespace-only — an empty/whitespace string is not a real conflicting value the user chose,
    # so it normalizes to ABSENT and the target is written (classified "added"), NOT "conflict".
    # A real non-empty string equal to the target is PRESENT-CANONICAL ("already present"); a real
    # non-empty string DIFFERING from the target is the genuine conflict, gated by approval below.
    # A present NON-STRING value (number/bool/object/array) is a real wrong-type value the user set
    # and is NOT in the normalized-ABSENT set: it is treated as a differing value (conflict branch).
    | ($s.agent) as $cur_agent
    | (($cur_agent | type) == "string"
       and (($cur_agent | gsub("^\\s+|\\s+$"; "")) == "")) as $agent_is_blank
    # ── agent conflict detection (PRESERVE-EXISTING; overwrite ONLY with explicit approval) ──
    # Differing existing agent: classify "overwritten" when the caller passed approved=="yes"
    # (the navigator sets this ONLY after user approval), else "conflict" (never overwrite).
    | (if ($cur_agent == null or $agent_is_blank) then "added"
       elif ($cur_agent == $agent) then "already present"
       elif ($agent_approved == "yes") then "overwritten"
       else "conflict" end) as $agent_class
    | (if $agent_class == "conflict"
       then {existing: $cur_agent, required: $agent}
       else null end) as $agent_conflict

    # ── permissions.allow union/append-if-absent (seed_allowlist = yes) ───────────
    # Keep existing entries in order, then append only template rules not already present.
    # $existing_allow is already canon_arr-normalized above (always an array, never null/wrong-typed),
    # so index()/$base + [...] cannot abort even when the source permissions.allow was wrong-typed.
    | (if $seed_allow == "yes"
       then $existing_allow
       else null end) as $base_allow
    | (if $seed_allow == "yes"
       then [ $template[] | . as $r | { rule: $r, result:
                ( if ($existing_allow | index($r)) != null
                  then "already present" else "added" end ) } ]
       else [] end) as $allow_report
    | (if $seed_allow == "yes"
       then ($base_allow + [ $template[] | . as $r | select( ($base_allow | index($r)) == null ) ])
       else $existing_allow end) as $merged_allow

    # ── required-key classification ──────────────────────────────────────────────
    | (if enabled_true("hivemind@brenpike") then "already present" else "added" end) as $c_hive
    | (if $caveman != "yes" then "resolved no"
       elif enabled_true("caveman@caveman") then "already present" else "added" end) as $c_cave
    | (if $claude_mem != "yes" then "resolved no"
       elif enabled_true("claude-mem@thedotmack") then "already present" else "added" end) as $c_mem
    | (if $codex != "yes" then "resolved no"
       elif enabled_true("codex@openai-codex") then "already present" else "added" end) as $c_codex
    # NESTED-LEAF classification: the contract value is pluginConfigs["caveman@caveman"]
    # .options.defaultLevel == "ultra", NOT the mere presence of the parent key. A parent
    # object present WITHOUT (or with a non-"ultra") defaultLevel is NOT configured for ultra
    # mode — it must be corrected (classified "added"). canon_obj normalizes the config object
    # and its .options so a wrong-typed nested container collapses to {} before the leaf read.
    | (if $caveman != "yes" then "resolved no"
       elif ((canon_obj($s.pluginConfigs) | canon_obj(.["caveman@caveman"]) | canon_obj(.options).defaultLevel) == "ultra")
         then "already present"
       else "added" end) as $c_pcfg
    | (if $caveman != "yes" then "resolved no"
       elif (canon_arr(canon_obj($s.hooks).SubagentStart)
            | any(canon_arr(.hooks) | any(.type == "command" and .command == ".claude/hooks/caveman-ultra-subagent.sh")))
         then "already present"
       else "added" end) as $c_hook

    # ── build the merged settings (PRESERVE-EXISTING) ────────────────────────────
    | $s
    # enabledPlugins required entry + conditional companion entries (add-if-absent: setpath
    # only widens, never removes a key the user already had).
    | .enabledPlugins = ($ep + {"hivemind@brenpike": true})
    | (if $caveman == "yes" then .enabledPlugins += {"caveman@caveman": true} else . end)
    | (if $claude_mem == "yes" then .enabledPlugins += {"claude-mem@thedotmack": true} else . end)
    | (if $codex == "yes" then .enabledPlugins += {"codex@openai-codex": true} else . end)
    # agent: write the target when absent, already equal, or "overwritten" (differing + approved);
    # on "conflict" (differing + NOT approved) leave the existing value byte-unchanged (the caller
    # stops blocked on $agent_conflict). Overwrite happens ONLY via the approved=="yes" gate.
    | (if $agent_class == "conflict" then . else .agent = $agent end)
    # caveman pluginConfigs — NESTED-LEAF merge (add/correct the specific
    # .options.defaultLevel == "ultra" leaf, PRESERVING every sibling key). The earlier
    # parent-presence test left an existing caveman config that lacked (or mis-set)
    # defaultLevel unchanged, so ultra mode was never actually configured. Here every
    # container on the path is canon_obj-normalized (the config object and its .options) so a
    # wrong-typed nested container collapses to {} BEFORE the leaf is set — a malformed config
    # can neither crash nor clobber. Sibling keys in the config object and in .options are kept;
    # only .options.defaultLevel is set to "ultra". Already-ultra → byte-stable no-op.
    | (if $caveman == "yes"
       then .pluginConfigs = (canon_obj(.pluginConfigs)
              | .["caveman@caveman"] = (canon_obj(.["caveman@caveman"])
                  | .options = (canon_obj(.options) | .defaultLevel = "ultra")))
       else . end)
    # caveman SubagentStart hook (add-if-absent on the SPECIFIC {type:"command", command} entry, NOT
    # on the presence of the SubagentStart key OR on the command alone): an existing unrelated
    # SubagentStart array is PRESERVED and the caveman entry is APPENDED to it. Already-present
    # requires an entry with BOTH .type == "command" AND that exact command wired — a command-matching
    # entry with a missing/wrong .type is an INVALID hook, so it does NOT count as present and the
    # canonical {type:"command", command} entry is appended beside it (the wrong-typed entry is left
    # in place). Re-merge of the canonical entry stays byte-stable and idempotent.
    | (if $caveman == "yes"
       then .hooks = (canon_obj(.hooks)
              | canon_arr(.SubagentStart) as $existing_subagent
              | if ($existing_subagent
                     | any(canon_arr(.hooks) | any(.type == "command" and .command == ".claude/hooks/caveman-ultra-subagent.sh")))
                then .
                else .SubagentStart = ($existing_subagent + [ { hooks: [ {
                       type: "command",
                       command: ".claude/hooks/caveman-ultra-subagent.sh"
                     } ] } ]) end)
       else . end)
    # permissions.allow union (seed_allowlist = yes): preserve sibling permissions keys.
    | (if $seed_allow == "yes"
       then .permissions = (($perm) | .allow = $merged_allow)
       else . end)
    | . as $merged

    # ── emit the OUTPUT CONTRACT object ──────────────────────────────────────────
    | {
        status: (if $agent_class == "conflict" then "conflict" else "ok" end),
        settings: $merged,
        agent_conflict: $agent_conflict,
        keys: {
          "enabledPlugins.hivemind@brenpike": $c_hive,
          "agent": $agent_class,
          "enabledPlugins.caveman@caveman": $c_cave,
          "enabledPlugins.claude-mem@thedotmack": $c_mem,
          "enabledPlugins.codex@openai-codex": $c_codex,
          "pluginConfigs.caveman@caveman": $c_pcfg,
          "hooks.SubagentStart": $c_hook
        },
        permissions_allow: $allow_report
      }'
}
