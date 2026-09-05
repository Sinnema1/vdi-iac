# Baseline versus orchestration: pilot protocol

## Hypothesis and current status

Primary hypothesis: orchestration reduces active human coordination minutes per
accepted completed workflow. Slice 001 supports the orchestration contract;
it does not establish this value proposition. No architectural invariants are
frozen by its outcome. No comparative trials have been completed.

## Six planned trials

Use three paired, bounded scanner-maintenance fixtures in fresh worktrees.
Pair the same initial defect across paths, use fresh worker context, and record
which path ran first. The reviewer must not coach the second worker with the
first worker's solution. Alternate path order to reduce order effects.

| Pair | Bounded task | First path | Second path |
| --- | --- | --- | --- |
| A | Restore rejection of an explicitly missing scanner target | Baseline | Orchestrated |
| B | Restore rejection of an explicitly named directory | Orchestrated | Baseline |
| C | Restore rejection of an unreadable explicit target | Baseline | Orchestrated |

Pair A is supported by the current fixture. B and C require narrow fixture
configuration before execution; they must use the unchanged native oracle.
Reject pair C on any host that bypasses file permissions instead of counting a
skipped assertion as success. These are study fixtures, not Slice 002.

Keep the model, effort setting, repository base SHA, validation commands,
attempt budget (two), and task instructions equivalent across each pair.
Record context reuse and any deviations. Do not use the already demonstrated
repair as a timed trial, or count synthetic injected failures as worker errors.

Baseline: the human submits the task to one coding agent, coordinates validation
and fixes, then accepts or rejects the result. Orchestrated: the human submits
the task, the runner accepts the engineering patch, validates and retries within
budget, and the human accepts or rejects. Count patch-handoff labor in the
orchestrated arm. This measures the current assisted runner; it cannot establish
the value of a future autonomous model integration.

## Measurement record

Create one record per trial, with unknown fields null until observed:

```json
{
  "trial_id": "A-baseline",
  "path": "baseline",
  "base_sha": null,
  "model_and_effort": null,
  "human_coordination_minutes": null,
  "human_interventions": null,
  "worker_attempts": null,
  "elapsed_minutes": null,
  "verification_failures": null,
  "post_completion_rework_minutes": null,
  "model_tool_cost_usd": null,
  "final_acceptance": null,
  "evidence_reference": null,
  "deviations": []
}
```

The human starts and stops a timer for active instruction, handoff, diagnosis,
status checking and review. Exclude unattended waiting. An intervention is one
human action needed to move the workflow forward, including initial submission
and final review; ordinary uninterrupted reading is timed but not a new action.
Log the timestamp, action and seconds for each interval. Do not estimate effort
from tool duration or message count. Report retrospective estimates separately.

Record wall-clock start at task submission and stop at human disposition.
Verification failures count failed post-worker validations, excluding the initial
seed proof. Preserve actual attempts including abandoned ones. Record final
acceptance only after human review and required checks, never from PR creation.
Observe rework until the next working day; mark the observation window incomplete
until then. Record all model/tool cost, including failed attempts; missing cost
stays unknown. Account-level usage percentages are not task cost measurements.

## Analysis and progression

Report acceptance rate for all trials and list rejected or incomplete trials.
For each path, divide total human coordination minutes across all attempted
trials by accepted completions. If there are no accepted completions, leave the
ratio undefined. Also show paired differences and raw observations so failures
are not hidden by averages. Summarize interventions, elapsed time, attempts,
verification failures and rework beside that primary outcome.

Cost amplification is total orchestration-path cost divided by total baseline
cost for the matched sample. Report it only when every component is known and
the denominator is positive. Three pairs are directional evidence with learning
and task-selection limitations, not statistical proof. Extend to five pairs if
results are mixed; do not select only favorable tasks.

After this measurement, select a real unseeded maintenance need for Slice 002.
Its solution must be unknown to the worker and acceptance machine-verifiable.
Only then revisit architectural invariants using the observed findings.
