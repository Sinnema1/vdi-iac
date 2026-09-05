"""Slice 001: local, single-host orchestration; explicitly approved draft publication."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
import signal
from pathlib import Path
import sqlite3
import subprocess
import time
import uuid

TARGET = 'scripts/ci/check-public-boundary.sh'
GOOD = '''      echo "public-boundary: '$file' does not exist" >&2
      exit 2'''
BAD = GOOD.replace('exit 2', 'exit 0')
VALIDATION_TIMEOUT = 120
CHECKS = [('regression', ['bash', 'tests/test-public-boundary.sh']),
          ('boundary', ['bash', TARGET])]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command(cwd, *args, timeout=120):
    result = subprocess.run(args, cwd=cwd, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace'))
    return result.stdout


class LocalRunner:
    """Replaceable driver: domain records and patch/evidence contracts are durable.

    One exclusive host lock covers every mutation, including activity execution.
    Recovery abandons an uncertain attempt; it never replays it in place.
    """

    def __init__(self, root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.root / 'state.sqlite')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS executions (id TEXT PRIMARY KEY, data TEXT NOT NULL);
        ''')

    @contextmanager
    def lock(self):
        with (self.root / 'runner.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield

    def get(self, table, key):
        row = self.db.execute(f'SELECT data FROM {table} WHERE id=?', (key,)).fetchone()
        if row is None:
            raise ValueError('Unknown record')
        return json.loads(row[0])

    def save(self, table, value):
        self.db.execute(f'INSERT OR REPLACE INTO {table} VALUES (?, ?)',
                        (value['id'], json.dumps(value)))

    def executions(self, task):
        rows = self.db.execute('SELECT data FROM executions').fetchall()
        return sorted((json.loads(r[0]) for r in rows
                       if json.loads(r[0])['task_id'] == task), key=lambda e: e['number'])

    def create(self, repo, intent, max_attempts=2):
        repo = Path(repo).resolve()
        if not intent.strip() or not 1 <= max_attempts <= 3:
            raise ValueError('Intent required; max attempts must be 1..3')
        if command(repo, 'git', 'status', '--porcelain').strip():
            raise ValueError('Use a clean committed repository as the pinned input')
        if self.root == repo or repo in self.root.parents:
            raise ValueError('State directory must be outside the repository')
        base = command(repo, 'git', 'rev-parse', 'HEAD').decode().strip()
        source = command(repo, 'git', 'show', f'{base}:{TARGET}').decode()
        if source.count(GOOD) != 1:
            raise ValueError('Seed precondition does not match this repository revision')
        task = dict(id=uuid.uuid4().hex, intent=intent, repo=str(repo), base=base,
                    status='READY', max_attempts=max_attempts, created_at=time.time(),
                    escalations=0, coordination_seconds=None, approval=None)
        with self.lock(), self.db:
            self.save('tasks', task)
        return task

    def attempt(self, task_id, patch, worker='engineering-patch', cost_usd=None):
        if cost_usd is not None and (not math.isfinite(cost_usd) or cost_usd < 0):
            raise ValueError('Cost must be finite and nonnegative, or unknown')
        patch = Path(patch).read_bytes()
        with self.lock():
            task = self.get('tasks', task_id)
            previous = self.executions(task_id)
            if task['status'] != 'READY' or len(previous) >= task['max_attempts']:
                raise ValueError('Task is not runnable; recover an interrupted attempt first')
            execution = dict(id=uuid.uuid4().hex, task_id=task_id,
                             number=len(previous) + 1, status='RUNNING',
                             started_at=time.time(), worker=worker, cost_usd=cost_usd,
                             validations=[], artifacts={})
            execution['branch'] = f"slice001/{task_id}/{execution['number']}"
            folder = self.root / execution['id']
            folder.mkdir()
            execution['worktree'] = str(folder / 'worktree')
            task['status'] = 'RUNNING'
            with self.db:
                self.save('executions', execution)
                self.save('tasks', task)
            try:
                self._activity(task, execution, folder, patch)
                execution['status'] = 'SUCCEEDED'
                task['status'] = 'AWAITING_APPROVAL'
            except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError) as error:
                execution['status'] = 'FAILED'
                execution['error'] = str(error)
                self._retry_or_escalate(task, execution['number'])
            execution['finished_at'] = time.time()
            with self.db:
                self.save('executions', execution)
                self.save('tasks', task)
            return self.report(task_id)

    def _artifact(self, execution, folder, name, data):
        path = folder / name
        # Exclusive creation prevents accidental overwrite on replay.
        with path.open('xb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        execution['artifacts'][name] = dict(path=str(path), sha256=digest(data))
        with self.db:
            self.save('executions', execution)

    def _validate(self, execution, folder, name, argv):
        started = time.time()
        try:
            process = subprocess.Popen(argv, cwd=execution['worktree'], stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                output, _ = process.communicate(timeout=VALIDATION_TIMEOUT)
                code = process.returncode
            except BaseException:
                os.killpg(process.pid, signal.SIGKILL)
                output, _ = process.communicate()
                raise
        except subprocess.TimeoutExpired:
            code = 124
        self._artifact(execution, folder, name + '.log', output)
        execution['validations'].append(dict(name=name, command=argv, exit_code=code,
                                            seconds=time.time() - started))
        with self.db:
            self.save('executions', execution)
        return code

    def _activity(self, task, execution, folder, patch):
        worktree = execution['worktree']
        command(task['repo'], 'git', 'worktree', 'add', '-b', execution['branch'],
                worktree, task['base'])
        target = Path(worktree) / TARGET
        original = target.read_text()
        if original.count(GOOD) != 1:
            raise ValueError('Seed precondition changed')
        target.write_text(original.replace(GOOD, BAD))
        self._artifact(execution, folder, 'seed.diff', command(worktree, 'git', 'diff'))
        if self._validate(execution, folder, 'seed-regression', CHECKS[0][1]) != 1:
            raise ValueError('Seed must fail the existing regression oracle with exit 1')
        command(worktree, 'git', '-c', 'user.name=Slice experiment', '-c',
                'user.email=slice@example.com', '-c', 'core.hooksPath=/dev/null',
                'commit', '-am', 'Seed missing-input regression in isolated experiment')
        execution['seed_commit'] = command(worktree, 'git', 'rev-parse', 'HEAD').decode().strip()
        self._artifact(execution, folder, 'worker.patch', patch)
        if not patch.strip():
            raise ValueError('Worker returned no patch')
        # Apply in a disposable index first, before executing any changed code.
        command(worktree, 'git', 'apply', '--index', str(folder / 'worker.patch'))
        changed = command(worktree, 'git', 'diff', '--cached', '--name-only').decode().splitlines()
        if changed != [TARGET]:
            raise ValueError('Worker may change only the seeded scanner file')
        mode = command(worktree, 'git', 'ls-files', '-s', TARGET).decode().split()[0]
        if mode != '100755' or target.is_symlink():
            raise ValueError('Worker may not change target file type or mode')
        self._artifact(execution, folder, 'repair.diff',
                       command(worktree, 'git', 'diff', '--cached', '--binary'))
        codes = [self._validate(execution, folder, name, argv) for name, argv in CHECKS]
        if any(codes):
            raise ValueError('Repository validation failed')
        # This experiment repairs one seeded defect, without expanding scanner policy.
        if target.read_text() != original:
            raise ValueError('Repair must restore the pinned scanner policy exactly')
        self._artifact(execution, folder, 'base.diff',
                       command(worktree, 'git', 'diff', task['base']))
        execution['tree'] = command(worktree, 'git', 'write-tree').decode().strip()

    def _retry_or_escalate(self, task, count):
        task['status'] = 'READY' if count < task['max_attempts'] else 'ESCALATED'
        if task['status'] == 'ESCALATED':
            task['escalations'] += 1

    def recover(self, task_id):
        with self.lock(), self.db:
            task = self.get('tasks', task_id)
            if task['status'] != 'RUNNING':
                return task
            execution = self.executions(task_id)[-1]
            execution.update(status='INTERRUPTED', finished_at=time.time(),
                             error='Host restarted or activity interrupted; worktree retained')
            self._retry_or_escalate(task, execution['number'])
            self.save('executions', execution)
            self.save('tasks', task)
            return task

    def approve(self, task_id, packet_sha256, reviewer, coordination_seconds=None):
        if not reviewer.strip() or (coordination_seconds is not None and
                                   (not math.isfinite(coordination_seconds) or coordination_seconds < 0)):
            raise ValueError('Reviewer and finite nonnegative coordination time required')
        with self.lock(), self.db:
            report = self.report(task_id)
            task = report['task']
            if task['status'] != 'AWAITING_APPROVAL' or report['packet_sha256'] != packet_sha256:
                raise ValueError('Approval must refer to the current successful evidence packet')
            self._revalidate(report)
            task.update(status='APPROVED', approval=dict(reviewer=reviewer,
                        packet_sha256=packet_sha256, at=time.time()),
                        coordination_seconds=coordination_seconds)
            self.save('tasks', task)
            return task

    def _revalidate(self, report):
        execution = report['executions'][-1]
        for artifact in execution['artifacts'].values():
            if digest(Path(artifact['path']).read_bytes()) != artifact['sha256']:
                raise ValueError('Evidence changed since validation')
        worktree = execution['worktree']
        if command(worktree, 'git', 'rev-parse', 'HEAD').decode().strip() != execution['seed_commit']:
            raise ValueError('Execution HEAD changed since validation')
        if command(worktree, 'git', 'write-tree').decode().strip() != execution['tree']:
            raise ValueError('Index changed since validation')
        if command(worktree, 'git', 'diff').strip() or command(worktree, 'git', 'ls-files', '--others', '--exclude-standard').strip():
            raise ValueError('Worktree changed since validation')

    def report(self, task_id):
        task = self.get('tasks', task_id)
        executions = self.executions(task_id)
        packet = dict(task_id=task_id, base=task['base'], executions=executions)
        return dict(task=task, executions=executions,
                    packet_sha256=digest(json.dumps(packet, sort_keys=True).encode()),
                    metrics=dict(attempts=len(executions), escalations=task['escalations'],
                                 coordination_seconds=task['coordination_seconds'],
                                 elapsed_seconds=(executions[-1].get('finished_at', time.time())
                                                  if executions else time.time()) - task['created_at'],
                                 cost_usd=(sum(e['cost_usd'] for e in executions)
                                           if executions and all(e['cost_usd'] is not None for e in executions)
                                           else None)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', required=True, help='Private durable directory outside the repository')
    sub = parser.add_subparsers(dest='action', required=True)
    create = sub.add_parser('create')
    create.add_argument('--repo', required=True)
    create.add_argument('--intent', required=True)
    create.add_argument('--max-attempts', type=int, default=2)
    attempt = sub.add_parser('attempt')
    attempt.add_argument('task_id')
    attempt.add_argument('--patch', required=True)
    attempt.add_argument('--worker', default='engineering-patch')
    attempt.add_argument('--cost-usd', type=float)
    for action in ('report', 'recover'):
        sub.add_parser(action).add_argument('task_id')
    approve = sub.add_parser('approve')
    approve.add_argument('task_id')
    approve.add_argument('--packet-sha256', required=True)
    approve.add_argument('--reviewer', required=True)
    approve.add_argument('--coordination-seconds', type=float)
    args = vars(parser.parse_args())
    runner = LocalRunner(args.pop('state'))
    result = getattr(runner, args.pop('action'))(**args)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
