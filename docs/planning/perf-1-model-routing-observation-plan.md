# PERF-1 Model Routing — Observation Plan

## 1. Status

**Shipped (Phase 5):** Option A — TFP-only sonnet trigger. The orchestrator passes `model=sonnet` to coder agents when the task meets Trivial Fast Path (TFP) conditions. All other coder delegations use the default model (opus).

**Deferred:**

- **Option B** — planner-output inspection. Tasks routed through the planner that produce a simple single-file plan are not eligible for sonnet in this phase. The orchestrator cannot currently inspect planner output to determine simplicity, so these tasks default to opus regardless of actual complexity.
- **Haiku tier** — a third, lower-cost model tier for purely mechanical operations. Deferred pending stable Option A data and haiku capability evaluation.

## 2. What to Observe

**Sonnet path utilization:** Which task types are actually hitting the sonnet path in practice. Expected candidates include TFP-eligible tasks (trivial single-file edits under 20 lines), version bump file edits, and simple review-remediation fixes that meet TFP criteria.

**False negatives (opus used where sonnet would suffice):** Tasks that could have used sonnet but were routed to opus because they did not meet TFP conditions. Primary category: planner-routed tasks where the planner returns a single-step, single-file, single-owner plan with no architecture concerns, version impact, or review-remediation complexity. Secondary category: non-TFP tasks that are simple in practice but exceed one of the TFP thresholds (e.g., touching two files where both changes are mechanical).

**False positives (sonnet used where opus was needed):** Tasks routed to sonnet that failed or produced lower-quality output attributable to model capability limits rather than task specification issues. Indicators: coder task failure on a sonnet-routed delegation, follow-up remediation required on sonnet-routed output that would not have been needed with opus, or quality regressions surfaced during review of sonnet-routed changes.

**Cost impact:** Rough estimate of the sonnet vs opus split across typical workflow sessions. Track the percentage of coder delegations hitting TFP (and therefore sonnet), and compare aggregate model cost against the pre-PERF-1 baseline where all coder delegations used opus.

## 3. Success Criteria for Option A

- Sonnet-routed tasks complete at the same quality level as equivalent tasks would under opus, with no observable degradation in output correctness, completeness, or adherence to governance constraints.
- No regressions or blocked states attributable to the model downgrade. Specifically: no coder failures, no review-remediation loops, and no scope-drift incidents caused by sonnet-routed tasks producing incomplete or incorrect output.
- Measurable cost reduction compared to the pre-PERF-1 baseline. Even a modest reduction validates the routing mechanism, since TFP tasks are a subset of all coder delegations.
- False positive rate near zero. No sonnet-routed tasks should fail due to model capability limitations. If any false positives are observed, the TFP conditions must be tightened before expanding sonnet eligibility.

## 4. Signals to Move to Option B (Planner-Output Inspection)

- **High false-negative rate:** Observation shows that a significant proportion of planner-routed tasks are demonstrably simple (single-step, single-file plans) but receive opus because they bypassed TFP. If more than half of planner-routed coder delegations produce single-step plans, the optimization opportunity from Option B is substantial.
- **Low TFP hit rate:** If fewer than 20% of coder delegations qualify for TFP, the cost savings from Option A alone are marginal. Option B would expand the sonnet-eligible pool meaningfully by capturing planner-routed simple tasks.
- **Stable Option A behavior:** Option A must have been running with a near-zero false positive rate for at least one full phase cycle before Option B is considered. This establishes confidence that sonnet handles simple tasks reliably and that the routing mechanism itself is sound.
- **Implementation risk is acceptable:** Option B introduces planner-output parsing into the orchestrator's routing logic. This should only proceed after confirming that planner report structure is stable and that parsing errors can be handled safely (defaulting to opus on any ambiguity).

## 5. Option B Design Notes (for future reference)

**Definition of "simple planner output":** A planner report qualifies as simple when all of the following are true:

- The plan contains exactly one step.
- The step assigns exactly one owner agent (coder).
- The step's file scope contains exactly one file.
- The plan raises no architecture concerns.
- The plan's versioning impact is "none" or "no bump required."
- The plan contains no review-remediation items or dependencies on prior PR feedback.

**How the orchestrator would inspect:** After the planner returns its report, the orchestrator checks the Steps count, the Versioning Impact field, and the presence of review-remediation or open-question items. If all criteria above are met, the orchestrator passes `model=sonnet` to the coder delegation for that step. If any criterion is not met or any field is missing/unparseable, the orchestrator uses the default model (opus).

**Risk:** Planner output parsing errors could misclassify a complex task as simple, leading to a sonnet-routed coder failing on work that requires opus-level reasoning. The fail-safe default must always be opus. Specifically:

- If the planner report is malformed or any field cannot be parsed, default to opus.
- If the planner report structure changes between versions, the parsing logic must detect the schema mismatch and default to opus rather than guessing.
- Option B parsing should be additive (new code path gated by a check) rather than modifying existing orchestrator routing to reduce regression risk.

## 6. Haiku Evaluation Criteria

**Candidate tasks:** Mechanical single-file operations with zero decision-making. Examples: renaming a variable across one file, reformatting a list to match an existing pattern, updating a single literal value (version string, date, URL) where the new value is provided explicitly in the delegation.

**Quality threshold:** Haiku must produce output identical to sonnet on the candidate task type. "Identical" means: same file content in the diff, same adherence to governance constraints, and no follow-up remediation needed. This must hold across N test sessions (minimum 10) per candidate task type before haiku is approved for that type.

**Cost-benefit:** Haiku saves over sonnet only if the task type is both frequent enough to accumulate meaningful savings and truly mechanical enough that haiku's lower capability ceiling is never the bottleneck. If a candidate task type occurs fewer than once per 10 workflow sessions, the savings are negligible and the added routing complexity is not justified.

**Recommendation:** Evaluate haiku eligibility only after Option A has been stable for at least one full phase cycle. Use the false-positive and false-negative data collected during Option A observation to identify which task types are genuinely mechanical. Begin haiku trials on the most frequent, most mechanical task type first and expand incrementally.
