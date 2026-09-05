"""Integration tests use real Git worktrees and repository-native shell checks."""
import difflib
import fcntl
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from publication import GitHubPublisher, Publication
from runner import BAD, GOOD, TARGET, LocalRunner, command

REPO = Path(__file__).resolve().parents[2]


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        command(REPO, 'git', 'clone', '--quiet', '--no-hardlinks', str(REPO), str(self.repo))
        self.runner = LocalRunner(self.root / 'state')
        self.addCleanup(self.runner.db.close)
        self.source = (self.repo / TARGET).read_text()
        self.patch = self.make_patch(self.source)
        self.task = self.runner.create(self.repo, 'Restore missing-target fail-closed behavior')

    def make_patch(self, repaired):
        patch = self.root / ('patch-' + str(time.time_ns()))
        patch.write_text(''.join(difflib.unified_diff(
            self.source.replace(GOOD, BAD).splitlines(True), repaired.splitlines(True),
            fromfile='a/' + TARGET, tofile='b/' + TARGET)))
        return patch

    def test_success_and_approval(self):
        report = self.runner.attempt(self.task['id'], self.patch)
        self.assertEqual('AWAITING_APPROVAL', report['task']['status'])
        self.assertEqual([1, 0, 0], [v['exit_code'] for v in report['executions'][0]['validations']])
        self.assertIsNone(report['metrics']['cost_usd'])
        with self.assertRaises(ValueError):
            self.runner.approve(self.task['id'], 'stale', 'reviewer', 4)
        approved = self.runner.approve(self.task['id'], report['packet_sha256'], 'reviewer', 4)
        self.assertEqual('APPROVED', approved['status'])
        self.assertEqual(4, approved['coordination_seconds'])
        self.assertEqual(b'', command(self.repo, 'git', 'status', '--porcelain'))
        with self.assertRaises(ValueError):
            self.runner.attempt(self.task['id'], self.patch)

    def test_failed_validation_then_retry_survives_restart(self):
        wrong = self.make_patch(self.source.replace(GOOD, GOOD.replace('exit 2', 'exit 1')))
        first = self.runner.attempt(self.task['id'], wrong, cost_usd=0.1)
        self.assertEqual('READY', first['task']['status'])
        self.assertEqual('FAILED', first['executions'][0]['status'])
        self.assertEqual(1, first['executions'][0]['validations'][1]['exit_code'])
        reopened = LocalRunner(self.root / 'state')
        self.addCleanup(reopened.db.close)
        second = reopened.attempt(self.task['id'], self.patch, cost_usd=0.2)
        self.assertEqual('AWAITING_APPROVAL', second['task']['status'])
        self.assertEqual(2, second['metrics']['attempts'])
        self.assertAlmostEqual(0.3, second['metrics']['cost_usd'])
        self.assertNotEqual(*[e['worktree'] for e in second['executions']])

    def test_retry_budget_escalates(self):
        empty = self.root / 'empty.patch'
        empty.write_text('')
        for _ in range(2):
            report = self.runner.attempt(self.task['id'], empty)
        self.assertEqual('ESCALATED', report['task']['status'])
        self.assertEqual(1, report['metrics']['escalations'])
        with self.assertRaises(ValueError):
            self.runner.attempt(self.task['id'], self.patch)

    def test_crash_recovery_does_not_replay_uncertain_attempt(self):
        original = self.runner._activity
        def crash(*args):
            raise KeyboardInterrupt('simulated process loss after durable start')
        self.runner._activity = crash
        with self.assertRaises(KeyboardInterrupt):
            self.runner.attempt(self.task['id'], self.patch)
        self.runner._activity = original
        self.assertEqual('RUNNING', self.runner.get('tasks', self.task['id'])['status'])
        self.runner.recover(self.task['id'])
        report = self.runner.attempt(self.task['id'], self.patch)
        self.assertEqual(['INTERRUPTED', 'SUCCEEDED'], [e['status'] for e in report['executions']])
        self.runner.recover(self.task['id'])
        self.assertEqual(2, len(self.runner.executions(self.task['id'])))

    def test_evidence_tamper_blocks_approval(self):
        report = self.runner.attempt(self.task['id'], self.patch)
        artifact = report['executions'][-1]['artifacts']['repair.diff']
        Path(artifact['path']).write_text('tampered')
        with self.assertRaises(ValueError):
            self.runner.approve(self.task['id'], report['packet_sha256'], 'reviewer', 0)

    def test_worktree_tamper_blocks_approval(self):
        report = self.runner.attempt(self.task['id'], self.patch)
        (Path(report['executions'][-1]['worktree']) / TARGET).write_text('tampered')
        with self.assertRaises(ValueError):
            self.runner.approve(self.task['id'], report['packet_sha256'], 'reviewer', 0)

    def test_worker_cannot_modify_oracle(self):
        self.patch.write_text(self.patch.read_text() + ''.join(difflib.unified_diff(
            (self.repo / 'tests/test-public-boundary.sh').read_text().splitlines(True),
            ['#!/usr/bin/env bash\n', 'exit 0\n'],
            fromfile='a/tests/test-public-boundary.sh', tofile='b/tests/test-public-boundary.sh')))
        report = self.runner.attempt(self.task['id'], self.patch)
        self.assertEqual('FAILED', report['executions'][0]['status'])
        self.assertEqual(1, len(report['executions'][0]['validations']))

    def test_timeout_is_failed_validation_with_evidence(self):
        execution = dict(id='timeout-probe', task_id=self.task['id'], number=1,
                         worktree=str(self.repo), artifacts={}, validations=[])
        with patch('runner.VALIDATION_TIMEOUT', 0.05):
            code = self.runner._validate(execution, self.root, 'timeout',
                                         ['bash', '-c', 'sleep 10'])
        self.assertEqual(124, code)
        self.assertTrue((self.root / 'timeout.log').exists())
        self.assertLess(execution['validations'][0]['seconds'], 5)

    def test_changed_head_blocks_approval(self):
        report = self.runner.attempt(self.task['id'], self.patch)
        worktree = report['executions'][-1]['worktree']
        command(worktree, 'git', '-c', 'user.name=Test', '-c',
                'user.email=test@example.com', '-c', 'core.hooksPath=/dev/null',
                'commit', '-m', 'Change execution HEAD')
        with self.assertRaises(ValueError):
            self.runner.approve(self.task['id'], report['packet_sha256'], 'reviewer', 0)

    def prepare_publication(self):
        report = self.runner.attempt(self.task['id'], self.patch)
        self.runner.approve(self.task['id'], report['packet_sha256'], 'reviewer')
        command(self.repo, 'git', 'remote', 'set-url', 'origin', 'https://github.com/example/project.git')
        command(self.repo, 'git', 'branch', '-f', 'review-base', 'HEAD')
        command(self.repo, 'git', 'switch', '-c', 'review-implementation')
        (self.repo / 'review-note.txt').write_text('Bounded implementation change.\n')
        command(self.repo, 'git', 'add', 'review-note.txt')
        command(self.repo, 'git', '-c', 'user.name=Test', '-c',
                'user.email=test@example.com', '-c', 'core.hooksPath=/dev/null',
                'commit', '-m', 'Prepare reviewed implementation')
        body = self.root / 'body.md'
        body.write_text('Review the bounded implementation.')
        publication = Publication(self.runner)
        prepared = publication.prepare(self.task['id'], 'Review implementation', body, 'review-base')
        return publication, prepared

    def test_publication_requires_approval_and_resumes_after_restart(self):
        publication, prepared = self.prepare_publication()
        publisher = Mock()
        publisher.publish.return_value = 'https://github.com/example/project/pull/1'
        with self.assertRaises(ValueError):
            publication.resume(self.task['id'], publisher)
        publisher.publish.assert_not_called()
        publication.approve(self.task['id'], prepared['digest'], 'reviewer')
        reopened = LocalRunner(self.root / 'state')
        self.addCleanup(reopened.db.close)
        resumed = Publication(reopened)
        self.assertEqual('PR_CREATED', resumed.resume(self.task['id'], publisher)['status'])
        resumed.resume(self.task['id'], publisher)
        publisher.publish.assert_called_once()

    def test_publication_revalidates_after_approval(self):
        publication, prepared = self.prepare_publication()
        publication.approve(self.task['id'], prepared['digest'], 'reviewer')
        (self.repo / 'review-note.txt').write_text('Changed after approval')
        publisher = Mock()
        with self.assertRaises(ValueError):
            publication.resume(self.task['id'], publisher)
        publisher.publish.assert_not_called()

    def test_publication_uncertain_response_is_recoverable(self):
        publication, prepared = self.prepare_publication()
        publication.approve(self.task['id'], prepared['digest'], 'reviewer')
        publisher = Mock()
        publisher.publish.side_effect = [RuntimeError('lost response'),
                                         'https://github.com/example/project/pull/1']
        with self.assertRaises(RuntimeError):
            publication.resume(self.task['id'], publisher)
        self.assertEqual('PUBLISHING', self.runner.get('tasks', self.task['id'])['publication']['status'])
        self.assertEqual('PR_CREATED', publication.resume(self.task['id'], publisher)['status'])

    def test_concurrent_driver_is_rejected(self):
        with (self.runner.root / 'runner.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.runner.attempt(self.task['id'], self.patch)


class PublisherTests(unittest.TestCase):
    def candidate(self):
        return dict(repo='.', repository='example/project', branch='review',
                    head_sha='abc', base_branch='main', title='Review', body='Body')

    def test_lost_creation_response_reconciles_existing_pr(self):
        import json
        existing = [dict(url='https://github.com/example/project/pull/1',
                         headRefOid='abc', baseRefName='main', state='OPEN')]
        with patch('publication.command', side_effect=[b'', b'abc refs/heads/review',
                                                       json.dumps(existing).encode()]) as invoke:
            self.assertEqual(existing[0]['url'], GitHubPublisher().publish(self.candidate()))
        self.assertFalse(any('create' in call.args for call in invoke.call_args_list))

    def test_remote_mismatch_stops_before_pr_creation(self):
        with patch('publication.command', side_effect=[b'', b'changed refs/heads/review']) as invoke:
            with self.assertRaises(ValueError):
                GitHubPublisher().publish(self.candidate())
        self.assertEqual(2, invoke.call_count)


if __name__ == '__main__':
    unittest.main()
