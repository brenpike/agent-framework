Read this file when parsing Codex CLI stdout output in Procedure step 5.

## Output Schema (from codex-plugin-cc)

The review command returns rendered text to stdout — not JSON. Parse this text to extract structured data.

**Rendered text format:**

```
# Codex Review
Target: <ref>
<summary text>
- [Pn] Title — file:line_start-line_end
  body text
- [Pn] Title — file:line
  body text
```

Note: `Full review comments:` does NOT appear in native output and must not be used as a delimiter.

**Parsing rules:**

- **verdict:** `"needs-attention"` if any `[P0]`, `[P1]`, `[P2]`, or `[P3]` findings are present; `"approve"` if none.
- **summary:** all non-finding lines after the `Target:` line (lines that do not begin with `- [P0]`, `- [P1]`, `- [P2]`, `- [P3]`, or `- [P4]`). The `Full review comments:` header, if encountered, is treated as a non-finding line and included in summary or skipped (it does not delimit findings).
- **findings:** each line after `Target:` matching `^- \[P[0-4]\] ` prefix is a finding entry, regardless of position relative to any section header. Each `- [Pn] Title — file:line_start[-line_end]` entry, parsed as:
  - `severity`: `P0` → `critical`, `P1` → `critical`, `P2` → `high`, `P3` → `medium`, `P4` → `low`
  - `title`: text before ` — ` on the entry line
  - `file`: match `^(.+):(\d+)(?:-(\d+))?$` against the full location string — group 1 is the file path (handles Windows absolute paths such as `C:\...\file.md:53-56` where a naïve first-`:` split would yield only the drive letter)
  - `line_start`: group 2 of the same match; `line_end`: group 3 when present, otherwise same as `line_start`
  - `body`: indented continuation lines following the entry header
  - `recommendation`: extracted from body text, or empty string if not present
  - `confidence`: not present in rendered text format; set to `null` in normalized output
- **next_steps:** empty array (not present in rendered format)

## Internal Findings Schema (normalized output)

Normalize each finding by adding a stable `id` field (deterministic SHA-256 hash of `file + line_start + line_end + title`) and preserving all Codex fields. The `confidence` field is included but not used for filtering by default.

```json
{
  "verdict": "approve | needs-attention",
  "summary": "string",
  "findings": [
    {
      "id": "string (sha256 of file+line_start+line_end+title)",
      "severity": "string",
      "title": "string",
      "body": "string",
      "file": "string",
      "line_start": "number",
      "line_end": "number",
      "confidence": null,
      "recommendation": "string"
    }
  ],
  "next_steps": ["string"],
  "iteration": "number",
  "base": "string"
}
```
