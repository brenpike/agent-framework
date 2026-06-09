# tests/react-marker

Fixture home for `tools/test_react_marker.sh`, the offline behavioral runner for
`plugin/skills/github-review-loop/scripts/react-marker.sh` (issue #265).

`react-marker.sh` is driven entirely through its capture seam, which requires BOTH
`REACTMARKER_TEST_MODE=1` AND `REACTMARKER_CAPTURE_FILE`: the EYES reaction is
appended to a scratch capture file (one line per reaction, format
`REACT node=<NODE_ID> content=EYES`) instead of being issued against `gh`. The
simulated live mutation exit status is supplied via `REACTMARKER_REACT_STATUS` for
the failure-path case. Reason tokens asserted on the hard-failure paths are
`missing-node-id`, `unmapped-surface`, and `react-failed`.

The suite uses REAL production-shaped reviewer node ids — `IC_...` for a toplevel
IssueComment and `PRR_...` for a review PullRequestReview — not fake placeholder
ids, so validation-order bugs cannot hide behind a non-production node shape. The
inputs are short positional args (`NODE_ID`, `surface`, `candidate_url`) and the
assertions are over the captured reaction log, so the suite needs no on-disk
input/expected JSON fixtures — the capture files live in a disposable `mktemp -d`
tmpdir removed on `EXIT`.

This directory is the designated fixture home should a future case require a canned
on-disk fixture (it is referenced by `tools/validate.sh`'s self-test probe map for
issue #265); it is kept committed via this README so the home exists ahead of that
need.
