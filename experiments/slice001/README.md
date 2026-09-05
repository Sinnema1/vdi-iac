# Slice 001: durable maintenance experiment

This is proof of the orchestration contract, not proof of the V1 value
proposition. It is a single-host experiment independent of the image pipeline.
Python 3.10+ (standard library), Git and Bash are sufficient on macOS or Linux.
It never runs PowerShell, Packer, Windows provisioning, or a lab operation.

## Workload and engineering worker

The controller pins a clean repository commit. Each execution creates a branch
and worktree, changes the scanner's explicitly missing input exit from 2 to 0,
and requires the existing regression suite to fail. The seed is committed only
in the execution worktree. The implementation branch never weakens the scanner.

One engineering worker reads the pinned scanner and the existing missing-input
regression, and submits a unified Git patch against the seeded version. An AI
coding session can produce this file; provider conversation state is not needed
to resume. The local runner accepts the patch as its worker result, records its
hash and worker identity, and applies it without invoking another agent. This is
a patch handoff, not an unattended model API integration. There is no scripted
repair worker masquerading as an AI worker.

The controller permits changes only to the scanner, preserves the test oracle,
runs the native regression suite and public-boundary check, and requires exact
restoration of the pinned scanner policy. This deliberately narrow acceptance
rule bounds the experiment; it is not a general software correctness oracle.
The repair diff is against the seeded commit. A successful base diff is empty:
this experiment demonstrates recovery of injected damage, not a new scanner fix.

## Run locally

Use a clean committed clone. Keep durable state and worker patches outside it.
The state directory contains local paths, full logs and Git worktrees; it is
private runtime evidence and must not be committed or published wholesale.

```bash
python3 experiments/slice001/runner.py --state ../slice001-state create \
  --repo . --intent 'Restore missing-input fail-closed behavior'
```

Save the returned task ID. Have the engineering worker supply `repair.patch`
against the seeded version of `scripts/ci/check-public-boundary.sh`.

```bash
python3 experiments/slice001/runner.py --state ../slice001-state attempt \
  TASK_ID --patch ../repair.patch --worker engineering-session
python3 experiments/slice001/runner.py --state ../slice001-state report TASK_ID
```

A failed execution leaves the task READY while budget remains (default two,
maximum three). Submit a revised patch with another `attempt` command. Every
attempt starts from the same pinned base in a fresh worktree. There is no hidden
model retry or timer. A process interruption leaves RUNNING durably recorded:

```bash
python3 experiments/slice001/runner.py --state ../slice001-state recover TASK_ID
```

Recovery takes the host lock, marks the uncertain attempt INTERRUPTED, and
consumes its attempt budget. It retains evidence and worktrees for inspection.
Repeated recovery is a no-op. Budget exhaustion leaves ESCALATED for a human.
Validation has a 120-second timeout and kills its process group on interruption.

## Approval and metrics

Success means AWAITING_APPROVAL. Inspect `repair.diff`, `seed.diff`, `base.diff`,
validation logs, and the report. The report provides a packet digest. A human
can explicitly record approval for that exact packet:

```bash
python3 experiments/slice001/runner.py --state ../slice001-state approve \
  TASK_ID --packet-sha256 DIGEST --reviewer reviewer \
  --coordination-seconds 45
```

The optional time is a human-supplied total of active coordination and review effort,
not wall-clock waiting time. It remains unknown until supplied. Attempts,
escalations, individual validation exit codes and durations, execution start/end
timestamps, and task elapsed time are recorded. Optional `--cost-usd` records
worker-reported execution cost; an unknown component makes the total unknown.
Do not infer cost from account usage or invent a dollar estimate.

Approval rejects changed evidence, staged changes, unstaged changes, and new
untracked files. APPROVED is a durable execution review result. The seeded
repair has an empty base diff, so its approval cannot authorize publication of
the implementation itself. `publication.py` binds a separate approval to the
implementation HEAD, diff, repository, branch, PR title and body.

```bash
python3 experiments/slice001/publication.py --state ../slice001-state prepare \
  TASK_ID --title 'Bounded orchestration contract experiment' \
  --body-file ../pr-body.md
python3 experiments/slice001/publication.py --state ../slice001-state approve \
  TASK_ID --packet-digest DIGEST --reviewer reviewer
python3 experiments/slice001/publication.py --state ../slice001-state resume TASK_ID
```

The trusted operator runs publication with authenticated Git and GitHub CLI.
Resume revalidates execution evidence and the exact implementation state before
pushing the approved SHA and creating a draft PR. An uncertain remote response
leaves PUBLISHING durably recorded; resume reconciles an existing PR before
creating one. A completed resume is a no-op. Existing closed or mismatched PRs
require human disposition. No merge or deployment operation exists.

Publication credentials belong to the trusted operator, not the patch worker.
GitHub branch protection and a trusted host remain necessary against concurrent
external writers; local checks do not make distributed publication atomic.
Remote CI evidence must identify the PR head SHA and workflow-run identity.
PR creation is not final acceptance and does not imply a green CI result.

## Trust and limitations

Worktrees isolate changes, not operating-system authority. This local pilot
assumes a trusted host, trusted operator and reviewed worker patches. It does
not sandbox arbitrary shell code, authenticate reviewer identity, or withstand
a hostile process that can edit the SQLite database or shared Git metadata.
A remotely autonomous worker requires a credential-free container or equivalent
OS boundary before broadening this contract. No such isolation is claimed here.

SQLite transactions persist Task and TaskExecution records. Evidence is written
and synced before its hash is recorded; abandoned files after a crash are kept.
Keep the entire state directory and repository together for recovery. Deleting
it is not supported recovery. Backups, multi-host scheduling, authenticated
approval, and automatic model calls remain deferred.

Run integration tests with the same command used by CI:

```bash
python3 -m unittest discover -s experiments/slice001 -p 'test_*.py' -v
```
