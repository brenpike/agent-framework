---
check15-indented-fence-canary: frontmatter present so the frontmatter branch is exercised too
---

# CHECK 15 indented-fence canary target

This file is the target for the `SAFETY-CANARY` CHECK 15 fence-lexing self-test in
`tools/policy_check.sh`. Every occurrence of the CHECK 15 trigger token below sits inside a
fenced code block that is INDENTED, or inside a nested fence, and must therefore be invisible
to `check15_token_line_numbers`. The single occurrence the scanner is expected to report is
the prose one at the bottom, tagged with the structural end-of-line marker the self-test
greps for.

This file is NOT a fixture (fixture discovery is `safety-*.json` at the `tests/policy/` top
level). It lives under `tests/`, which CHECK 15 allowlists, so its occurrences are counted
as allowed rather than reported as findings during a normal run.

1. A one-space-indented fence, as list-continuation prose produces:

 ```yaml
 allowed-tools: Bash(node *)
 ```

2. A three-space-indented fence, the deepest indent CommonMark still calls a fence:

   ```yaml
   allowed-tools: Bash(node *)
   ```

3. A tilde fence, indented two spaces:

  ~~~yaml
  allowed-tools: Bash(node *)
  ~~~

4. A four-backtick outer fence containing a three-backtick inner fence. The inner run is
   shorter than the opener, so it must NOT close the outer block and the token between the
   inner delimiters must stay hidden:

````markdown
```yaml
allowed-tools: Bash(node *)
```
````

5. A fence whose CLOSER is indented although its opener is not. Retaining the delimiter means
   the indented closer still closes it:

```yaml
allowed-tools: Bash(node *)
   ```

6. Four leading spaces is an INDENTED CODE BLOCK, not a fence, so the backticks below open
   nothing and the block's contents remain ordinary scanned lines. No trigger token is placed
   here, because an indented code block is genuinely NOT exempt:

    ```text
    this line is inside an indented code block, not a fence
    ```

7. The prose occurrence, the ONLY line the scanner must report. It names the token in
   running text, which is exactly the shape CHECK 15 exists to contain, and it carries the
   end-of-line marker the self-test greps for so the expected line number is derived from
   the file rather than hard-coded:

   A surface must not assert `allowed-tools` engine behavior. CHECK15-FENCE-CANARY-PROSE

Do not reflow, re-indent, or unwrap the examples above: the indentation IS the test.
