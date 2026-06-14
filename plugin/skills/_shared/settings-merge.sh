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
# DATA, copied byte-for-byte from seed-hive/SKILL.md step 6. No other site re-states the rule
# list; a caller that needs the template calls the function. The rule ORDER is load-bearing
# (the create-from-absent path emits the array in template order); do not reorder, add, drop,
# or reword an entry without changing both this DATA and SKILL.md in lockstep.
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
#   - enabledPlugins["hivemind@brenpike"] = true — add-if-absent; idempotent.
#   - enabledPlugins["caveman@caveman"] / ["claude-mem@thedotmack"] / ["codex@openai-codex"]
#     = true — written ONLY when the matching companion flag resolves yes; add-if-absent.
#   - agent = "<agent_target>" — add-if-absent. CONFLICT DETECTION: if `agent` already holds a
#     DIFFERENT non-empty value, behavior is GATED by the 7th arg <agent_conflict_approved>:
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
#   - pluginConfigs["caveman@caveman"].options.defaultLevel = "ultra" — caveman=yes only.
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
#         "agent": "added" | "already present" | "unchanged" | "conflict" | "overwritten",
#         "enabledPlugins.caveman@caveman": "added" | "already present" | "resolved no",
#         "enabledPlugins.claude-mem@thedotmack": "...",
#         "enabledPlugins.codex@openai-codex": "...",
#         "pluginConfigs.caveman@caveman": "added" | "already present" | "resolved no",
#         "hooks.SubagentStart": "added" | "already present" | "resolved no"
#       },
#       "permissions_allow": [                   // one entry per template rule, in template
#         { "rule": <str>, "result": "added" | "already present" },   // order; [] when
#         ...                                                          // seed_allowlist=no
#       ]
#     }
#   `agent` classification: `added` (was absent), `already present`/`unchanged` (already equal
#   to the target — both map here; SKILL.md output allows either token), `conflict` (different
#   existing value AND not approved; the conflict block is populated and `.settings.agent` is the
#   existing value), `overwritten` (different existing value AND approved=="yes"; `.settings.agent`
#   is the target and the conflict block is null).
#
# DEPENDENCY: jq only (POSIX + jq). No yq, no sed/awk.

# hivemind_settings_permissions_template
# Emit the frozen least-privilege `permissions.allow` template, ONE rule per line, in the
# canonical (load-bearing) order. This is the SINGLE DATA source for the template (P1); the
# merge function reads it through this function, and any caller that needs to display or test
# the template uses it too. Pure: no side effects, no exit, reads no input.
#
# INVARIANT: this list is byte-for-byte the frozen template in seed-hive/SKILL.md step 6. The
# order is canonical and load-bearing (absent-array creation emits in this order). Do not
# reorder, add, drop, or reword an entry without updating SKILL.md in the same change.
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
Bash(node /path/to/.claude/plugins/cache/openai-codex/codex/*)
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
  # unparseable string is NOT coerced — report malformed so the caller fails closed rather than
  # silently erasing a torn real file.
  if [ -z "$settings_json" ]; then
    settings_json='{}'
  elif ! printf '%s' "$settings_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    # Unparseable JSON, or valid JSON that is not an object (a settings file must be an object).
    jq -n '{status:"malformed", settings:null, agent_conflict:null, keys:{}, permissions_allow:[]}'
    return 0
  fi

  # Build the template as a JSON array from the SINGLE DATA source, passed inert via --argjson.
  local template_json
  template_json="$(hivemind_settings_permissions_template | jq -R . | jq -s .)"

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
    # ── helpers ──────────────────────────────────────────────────────────────────
    # getpath-safe presence test for a nested key equal to a value.
    def has_enabled($k): ($settings.enabledPlugins // {}) | has($k);

    # The caveman SubagentStart hook entry, mirroring SKILL.md step 10d structure.
    ($settings) as $s
    | (($s.enabledPlugins) // {}) as $ep
    | (($s.permissions) // {}) as $perm
    | (($perm.allow) // null) as $existing_allow

    # ── agent conflict detection (PRESERVE-EXISTING; overwrite ONLY with explicit approval) ──
    # Differing existing agent: classify "overwritten" when the caller passed approved=="yes"
    # (the navigator sets this ONLY after user approval), else "conflict" (never overwrite).
    | ($s.agent) as $cur_agent
    | (if ($cur_agent == null) then "added"
       elif ($cur_agent == $agent) then "already present"
       elif ($agent_approved == "yes") then "overwritten"
       else "conflict" end) as $agent_class
    | (if $agent_class == "conflict"
       then {existing: $cur_agent, required: $agent}
       else null end) as $agent_conflict

    # ── permissions.allow union/append-if-absent (seed_allowlist = yes) ───────────
    # Keep existing entries in order, then append only template rules not already present.
    | (if $seed_allow == "yes"
       then ($existing_allow // [])
       else null end) as $base_allow
    | (if $seed_allow == "yes"
       then [ $template[] | . as $r | { rule: $r, result:
                ( if (($existing_allow // []) | index($r)) != null
                  then "already present" else "added" end ) } ]
       else [] end) as $allow_report
    | (if $seed_allow == "yes"
       then ($base_allow + [ $template[] | . as $r | select( ($base_allow | index($r)) == null ) ])
       else $existing_allow end) as $merged_allow

    # ── required-key classification ──────────────────────────────────────────────
    | (if has_enabled("hivemind@brenpike") then "already present" else "added" end) as $c_hive
    | (if $caveman != "yes" then "resolved no"
       elif has_enabled("caveman@caveman") then "already present" else "added" end) as $c_cave
    | (if $claude_mem != "yes" then "resolved no"
       elif has_enabled("claude-mem@thedotmack") then "already present" else "added" end) as $c_mem
    | (if $codex != "yes" then "resolved no"
       elif has_enabled("codex@openai-codex") then "already present" else "added" end) as $c_codex
    | (if $caveman != "yes" then "resolved no"
       elif (($s.pluginConfigs) // {} | has("caveman@caveman")) then "already present"
       else "added" end) as $c_pcfg
    | (if $caveman != "yes" then "resolved no"
       elif ((($s.hooks) // {} | .SubagentStart) // [])
            | any(.hooks // [] | any(.command == ".claude/hooks/caveman-ultra-subagent.sh"))
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
    # caveman pluginConfigs + SubagentStart hook (add-if-absent).
    | (if $caveman == "yes"
       then .pluginConfigs = (((.pluginConfigs) // {})
              | if has("caveman@caveman") then .
                else . + {"caveman@caveman": {options: {defaultLevel: "ultra"}}} end)
       else . end)
    # caveman SubagentStart hook (add-if-absent on the SPECIFIC command, NOT on the presence of
    # the SubagentStart key): an existing unrelated SubagentStart array is PRESERVED and the
    # caveman entry is APPENDED to it. Already-present requires that exact command be wired, so
    # re-merge stays byte-stable and idempotent.
    | (if $caveman == "yes"
       then .hooks = (((.hooks) // {})
              | (.SubagentStart // []) as $existing_subagent
              | if ($existing_subagent
                     | any(.hooks // [] | any(.command == ".claude/hooks/caveman-ultra-subagent.sh")))
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
