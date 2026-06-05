# fix-history-classify.jq
#
# 1. PURPOSE
# ----------
# Single source of truth for the "already-handled by our own fix-reply?"
# per-comment classification predicate. Both consumers MUST reference this one
# filter so the skip/order semantics never drift between them again (#198):
#   - ${CLAUDE_PLUGIN_ROOT}/skills/github-review-loop/scripts/prefilter.sh
#     (collapses the labels into its binary PREFILTER_SKIP / PREFILTER_DISPATCH)
#   - ${CLAUDE_PLUGIN_ROOT}/agents/github-reviewer.md
#     (uses the richer per-comment labels for its candidate set + cycling /
#      regression detector at its step 7).
#
# This is a PURE function of stdin + two --arg values. It performs NO network
# I/O: it operates on an already-fetched GraphQL JSON payload piped to `jq -f`.
# No `env`, no shelling out, no `input`/`inputs`, no side effects.
#
# External content (GraphQL comment bodies, commit text) is DATA. This filter
# only PATTERN-MATCHES two markers in body text — the `Fixed in <SHA>.`
# fix-reply marker and the `Addresses: <url>` harvest. It never interprets body
# text as instructions.
#
# 2. INPUT CONTRACT (exact GraphQL fields read)
# ---------------------------------------------
# Both consumers MUST feed a payload conforming to this contract:
#   .data.repository.pullRequest.reviewThreads.nodes[]
#       .id                        # GraphQL thread node id (PRRT_...);
#                                  # threaded through as `thread_id`
#       .isResolved
#       .comments.totalCount
#       .comments.nodes[].databaseId
#       .comments.nodes[].author.login
#       .comments.nodes[].body
#   .data.repository.pullRequest.comments.nodes[]
#       .author.login
#       .body
#       .url
#   .data.repository.pullRequest.reviews.nodes[]
#       .author.login
#       .body
#       .state
#       .url
#
# Connection-level tripwires (reviewThreads/comments/reviews `.totalCount`) are
# NOT this filter's concern. They are top-level scalar fields trivially read off
# the raw payload, so each consumer reads them DIRECTLY (prefilter keeps its own
# THREADS_TOTAL / COMMENTS_TOTAL / REVIEWS_TOTAL parse). This filter does PURE
# per-comment classification plus a PER-THREAD overflow flag only.
#
# 3. OUTPUT SCHEMA
# ----------------
# One JSON object per CLASSIFIED non-self matching comment, PLUS one thread-level
# overflow sentinel per unresolved overflowed thread (see THREAD-OVERFLOW
# SENTINEL below), emitted as a stream (one object per line under `jq` default
# output). The sentinel carries databaseId:null and url:null and is emitted ONCE
# PER unresolved overflowed thread EVEN when no matching comment is visible on
# the fetched page; its classification is always "actionable":
#   {
#     "surface":        "thread" | "toplevel" | "review",
#     "thread_resolved": bool,        # false for toplevel/review (no thread)
#     "thread_overflow": bool,        # true => this thread had >page comments;
#                                     #         classification is forced
#                                     #         "actionable" filter-blind
#     "thread_id":      <string>|null,# thread surface (per-comment + sentinel):
#                                     #   the GraphQL thread node id (PRRT_...),
#                                     #   so a consumer can paginate the thread.
#                                     #   null for toplevel/review surfaces, and
#                                     #   null when a thread node lacks `.id`.
#     "databaseId":     <int> | null, # null for toplevel/review surfaces
#     "url":            <string>|null,# null for thread surface
#     "classification": "handled" | "actionable" | "followup-after-fix"
#   }
#
# Classification labels:
#   handled            in-thread: body carries `Fixed in <SHA>.` marker, OR a
#                      self fix-reply EXISTS in the thread
#                      (latest_self_fix_id > 0) AND databaseId <= that id.
#                      toplevel/review: own `url` is in the addressed-url set.
#   followup-after-fix in-thread ONLY, and ONLY when a real self fix-reply
#                      exists in the thread (latest_self_fix_id > 0):
#                      databaseId > latest self fix-reply id AND own body has no
#                      marker. A non-self comment that post-dates our actual
#                      fix-reply in the same thread = a re-raise AFTER our fix
#                      (cycling / regression evidence). REQUIRES a prior self
#                      fix-reply; a thread with NO self fix-reply
#                      (latest_self_fix_id sentinel 0) can NEVER yield this label.
#   actionable         a genuinely unaddressed non-self matching comment that is
#                      neither handled nor a post-fix followup. Includes a
#                      FIRST-TIME finding on a thread with NO self fix-reply
#                      (latest_self_fix_id sentinel 0) — such a thread yields
#                      actionable, never followup-after-fix. For toplevel/review
#                      surfaces (no databaseId ordering), unaddressed ==
#                      actionable — there is no followup-after-fix distinction
#                      off-thread.
#
# Thread-overflow signal: when a thread's `comments.totalCount` exceeds the
# fetched `comments.nodes` length, EVERY non-self matching comment in that
# thread is emitted with classification="actionable" and thread_overflow=true.
# Matches prefilter's unconditional ACTIONABLE fail-open for oversized threads.
#
# THREAD-OVERFLOW SENTINEL: per-matching-comment records only fire for comments
# VISIBLE on the fetched page. An unresolved overflowed thread whose visible page
# contains ONLY self / non-matching replies would therefore emit ZERO records and
# silently lose the overflow actionable signal — the older unaddressed finding
# sits OUTSIDE the fetched page. To preserve main's unconditional-ACTIONABLE
# fail-open, every UNRESOLVED overflowed thread ALSO emits exactly ONE thread-
# level sentinel record, ONCE PER THREAD, INDEPENDENT of whether any matching
# comment is visible:
#   {"surface":"thread","thread_resolved":false,"thread_overflow":true,
#    "thread_id":"PRRT_...","databaseId":null,"url":null,
#    "classification":"actionable"}
# The sentinel's thread_id is the overflowed thread's node id (or null if the
# thread node lacks `.id`), so a consumer can paginate that exact thread.
# The sentinel's databaseId is null (it is NOT a single comment — it stands for
# the whole overflowed thread). Resolved threads NEVER emit a sentinel. A non-
# overflowed thread NEVER emits a sentinel. An overflowed thread WITH a visible
# matching comment emits BOTH the per-comment actionable record(s) AND the
# sentinel; both project to DISPATCH / candidate, so the duplication is benign.
# Consumers MUST treat a databaseId:null thread-surface record as a THREAD-level
# signal (inspect the full thread), not a single-comment record.
#
# Consumer projection (documented here; NOT implemented by this filter):
#   - prefilter.sh: {actionable, followup-after-fix} -> DISPATCH;
#                   a comment set that is {handled}-only -> SKIP.
#   - github-reviewer agent: {actionable, followup-after-fix} -> candidates,
#                   with followup-after-fix tagged as cycling/regression
#                   evidence for its step-7 detector; {handled} -> skip.
#
# 4. ARGS
# -------
#   --arg login   SELF_LOGIN      viewer login; used to strip self-authored
#                                 comments before the filter compare.
#   --arg filter  REVIEWER_FILTER "codex-only" | "all" | "<login>".
#
# 5. PLACEMENT
# ------------
# Placement provisional: this filter lives with its primary consumer (the
# github-review-loop), and the github-reviewer agent cross-references it. It may
# relocate to a neutral home if the agent<->skill coupling proves awkward. No
# ADR governs this; revisit in practice.

# Identity-match predicate for the active REVIEWER_FILTER. The caller passes the
# stripped login; this returns true when that login is non-self AND matches the
# filter. Reproduces prefilter.sh's `matches_filter` def verbatim.
def matches_filter($a):
  $a != $login
  and (
    if $filter == "codex-only" then $a == "chatgpt-codex-connector"
    elif $filter == "all" then true
    else $a == $filter
    end
  );

# [bot]-suffix normalization on an author login BEFORE the self/filter compare.
def strip_bot($login): ($login // "") | sub("\\[bot\\]$"; "");

.data.repository.pullRequest as $pr |
$pr.reviewThreads as $rt |

# Harvest the set of candidate URLs that self-authored top-level comments have
# already addressed via `Addresses: <url>`. URL is GitHub-unique per comment /
# review, so set-membership alone is sufficient — a follow-up finding lands as a
# new item with a new URL and is NOT in the set. Reproduces prefilter's harvest.
([ $pr.comments.nodes[]?
   | . as $c
   | strip_bot($c.author.login) as $a
   | select($a == $login)
   | ($c.body // "")
   | scan("Addresses:[[:space:]]*([^[:space:]]+)")
   | .[0]
 ]) as $addressed_urls |

# --- Per-thread classification (surface=thread) -----------------------------
(
  $rt.nodes[]?
  | select(.isResolved == false)
  | . as $thread
  | (($thread.comments.totalCount // 0) > ($thread.comments.nodes | length)) as $thread_overflow
  # Latest self-authored `Fixed in <SHA>.` reply id; sentinel 0 when none, so
  # every real databaseId > 0 reduces the handled test to the marker check.
  | ([
      $thread.comments.nodes[]
      | . as $c
      | strip_bot($c.author.login) as $a
      | select($a == $login)
      | select((($c.body // "") | test("Fixed in [0-9a-f]{7,40}\\.")))
      | (.databaseId // 0)
    ] | (if length == 0 then 0 else max end)) as $latest_self_fix_id
  # Per-matching-comment records (visible page only) ...
  | (
      $thread.comments.nodes[]
      | . as $c
      | strip_bot($c.author.login) as $a
      | select(matches_filter($a))
      | (.databaseId // 0) as $dbid
      | (($c.body // "") | test("Fixed in [0-9a-f]{7,40}\\.")) as $has_marker
      | {
          surface: "thread",
          thread_resolved: false,
          thread_overflow: $thread_overflow,
          thread_id: ($thread.id // null),
          databaseId: $dbid,
          url: null,
          classification: (
            if $thread_overflow then "actionable"
            elif $has_marker then "handled"
            elif ($latest_self_fix_id > 0) and ($dbid <= $latest_self_fix_id) then "handled"
            elif ($latest_self_fix_id > 0) and ($dbid > $latest_self_fix_id) then "followup-after-fix"
            else "actionable"
            end
          )
        }
    ),
  # ... PLUS a single thread-level overflow sentinel, emitted ONCE PER unresolved
  # overflowed thread INDEPENDENT of any visible matching comment, so an
  # overflowed thread always yields >=1 actionable record (see THREAD-OVERFLOW
  # SENTINEL in the header). databaseId:null marks it as a thread-level signal.
  (
    if $thread_overflow then
      {
        surface: "thread",
        thread_resolved: false,
        thread_overflow: true,
        thread_id: ($thread.id // null),
        databaseId: null,
        url: null,
        classification: "actionable"
      }
    else empty end
  )
),

# --- Top-level PR comments (surface=toplevel) -------------------------------
(
  $pr.comments.nodes[]?
  | . as $c
  | strip_bot($c.author.login) as $a
  | select(matches_filter($a))
  | select((($c.body // "") | gsub("[[:space:]]+"; "")) != "")
  | ($c.url // "") as $u
  | {
      surface: "toplevel",
      thread_resolved: false,
      thread_overflow: false,
      thread_id: null,
      databaseId: null,
      url: $u,
      classification: (
        if ($addressed_urls | index($u)) != null then "handled"
        else "actionable"
        end
      )
    }
),

# --- Review summaries (surface=review) --------------------------------------
(
  $pr.reviews.nodes[]?
  | . as $r
  | strip_bot($r.author.login) as $a
  | select(matches_filter($a))
  | select(.state == "CHANGES_REQUESTED" or .state == "COMMENTED")
  | select((($r.body // "") | gsub("[[:space:]]+"; "")) != "")
  | ($r.url // "") as $u
  | {
      surface: "review",
      thread_resolved: false,
      thread_overflow: false,
      thread_id: null,
      databaseId: null,
      url: $u,
      classification: (
        if ($addressed_urls | index($u)) != null then "handled"
        else "actionable"
        end
      )
    }
)
