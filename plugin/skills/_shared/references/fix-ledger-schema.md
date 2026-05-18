Read this file when initializing or updating the fix ledger in Procedure step 3.

## Fix Ledger Schema

```json
{
  "branch": "string",
  "base": "string",
  "max_iterations": 10,
  "iterations": [
    {
      "iteration": 1,
      "findings": [
        {
          "id": "string",
          "severity": "string",
          "title": "string",
          "body": "string",
          "recommendation": "string|null",
          "file": "string",
          "line_start": 0,
          "line_end": 0,
          "status": "open|fixing|fixed|regressed|cycling",
          "introduced_iteration": 1,
          "fixed_iteration": null,
          "fix_commit": null
        }
      ],
      "verdict": "approve|needs-attention",
      "exit_reason": null,
      "review_base_ref": null
    }
  ],
  "exit_reason": null,
  "exit_iteration": null
}
```

## Field notes

### `iterations[].review_base_ref` (string|null, optional, default null)

The commit SHA that was HEAD when this iteration's review pass began. Used by iteration N+1 to scope the review to only changes since this point. Null if the review was not invoked or was interrupted before recording. Omit the field entirely in existing ledgers — absent and null are treated identically.
