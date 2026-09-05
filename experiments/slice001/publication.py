"""Explicit publication of a separately reviewed implementation commit.

The seeded repair has an empty base diff. Its approval cannot authorize an
unrelated implementation diff; publication therefore has its own bound packet.
"""
import argparse
import json
from pathlib import Path
import re
import time
import tempfile

from runner import LocalRunner, command, digest


def fingerprint(value):
    return digest(json.dumps(value, sort_keys=True).encode())


class GitHubPublisher:
    def publish(self, candidate):
        repo = candidate['repo']
        slug = candidate['repository']
        branch = candidate['branch']
        sha = candidate['head_sha']
        # Explicit SHA refspec, never an implicit push of the current checkout.
        command(repo, 'git', 'push', 'origin', f'{sha}:refs/heads/{branch}')
        remote = command(repo, 'git', 'ls-remote', 'origin', f'refs/heads/{branch}').decode().split()
        if not remote or remote[0] != sha:
            raise ValueError('Remote branch no longer matches approved commit')
        existing = json.loads(command(repo, 'gh', 'pr', 'list', '--repo', slug,
                                      '--head', branch, '--state', 'all', '--json',
                                      'url,headRefOid,baseRefName,state'))
        if existing:
            if len(existing) != 1 or existing[0]['headRefOid'] != sha or existing[0]['baseRefName'] != candidate['base_branch']:
                raise ValueError('Existing PR does not match the approved publication')
            if existing[0]['state'] != 'OPEN':
                raise ValueError('Existing PR is closed; human disposition required')
            return existing[0]['url']
        # On uncertain response, resume queries before issuing another creation.
        with tempfile.NamedTemporaryFile(mode='w', suffix='.md') as body:
            body.write(candidate['body'])
            body.flush()
            return command(repo, 'gh', 'pr', 'create', '--repo', slug, '--draft',
                           '--base', candidate['base_branch'], '--head', branch,
                           '--title', candidate['title'], '--body-file', body.name).decode().strip()


class Publication:
    def __init__(self, runner):
        self.runner = runner

    def prepare(self, task_id, title, body_file, base_branch='main'):
        r = self.runner
        with r.lock(), r.db:
            report = r.report(task_id)
            task = report['task']
            if task['status'] != 'APPROVED' or 'publication' in task:
                raise ValueError('Execution must be approved; publication may be prepared only once')
            r._revalidate(report)
            repo = task['repo']
            if command(repo, 'git', 'status', '--porcelain').strip():
                raise ValueError('Implementation checkout must be clean')
            branch = command(repo, 'git', 'branch', '--show-current').decode().strip()
            if not branch or branch == base_branch or branch.startswith('slice001/'):
                raise ValueError('Publish an implementation branch, never a seeded execution branch')
            origin = command(repo, 'git', 'remote', 'get-url', 'origin').decode().strip()
            match = re.fullmatch(r'https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?', origin)
            if not match:
                raise ValueError('This pilot requires an explicit HTTPS GitHub origin')
            sha = command(repo, 'git', 'rev-parse', 'HEAD').decode().strip()
            base = command(repo, 'git', 'rev-parse', base_branch).decode().strip()
            diff = command(repo, 'git', 'diff', '--binary', base, sha)
            if not diff:
                raise ValueError('Implementation publication requires a nonempty diff')
            candidate = dict(repo=repo, repository=match[1], branch=branch, head_sha=sha,
                             base_branch=base_branch, base_sha=base, diff_sha256=digest(diff),
                             title=title, body=Path(body_file).read_text(),
                             execution_packet_sha256=report['packet_sha256'])
            task['publication'] = dict(candidate=candidate, digest=fingerprint(candidate),
                                       status='AWAITING_APPROVAL')
            r.save('tasks', task)
            return task['publication']

    def approve(self, task_id, packet_digest, reviewer):
        r = self.runner
        with r.lock(), r.db:
            task = r.get('tasks', task_id)
            pub = task['publication']
            if not reviewer.strip() or pub['status'] != 'AWAITING_APPROVAL' or pub['digest'] != packet_digest:
                raise ValueError('Approval must identify the exact publication packet')
            self._revalidate(task)
            pub.update(status='APPROVED', approval=dict(reviewer=reviewer, at=time.time(), digest=packet_digest))
            r.save('tasks', task)
            return pub

    def _revalidate(self, task):
        r = self.runner
        pub = task['publication']
        candidate = pub['candidate']
        report = r.report(task['id'])
        if task['status'] != 'APPROVED' or task['approval']['packet_sha256'] != report['packet_sha256']:
            raise ValueError('Execution approval no longer matches evidence')
        r._revalidate(report)
        if fingerprint(candidate) != pub['digest']:
            raise ValueError('Publication packet changed')
        repo = candidate['repo']
        if command(repo, 'git', 'status', '--porcelain').strip():
            raise ValueError('Implementation checkout changed')
        if command(repo, 'git', 'rev-parse', 'HEAD').decode().strip() != candidate['head_sha']:
            raise ValueError('Implementation HEAD changed')
        diff = command(repo, 'git', 'diff', '--binary', candidate['base_sha'], candidate['head_sha'])
        if digest(diff) != candidate['diff_sha256']:
            raise ValueError('Implementation diff changed')
        origin = command(repo, 'git', 'remote', 'get-url', 'origin').decode().strip()
        if origin not in [f"https://github.com/{candidate['repository']}", f"https://github.com/{candidate['repository']}.git"]:
            raise ValueError('Publication destination changed')

    def resume(self, task_id, publisher=None):
        r = self.runner
        with r.lock():
            task = r.get('tasks', task_id)
            pub = task['publication']
            if pub['status'] == 'PR_CREATED':
                return pub
            if pub['status'] not in ('APPROVED', 'PUBLISHING'):
                raise ValueError('Human publication approval required')
            if pub['approval']['digest'] != pub['digest']:
                raise ValueError('Publication approval is stale')
            self._revalidate(task)
            pub['status'] = 'PUBLISHING'
            with r.db:
                r.save('tasks', task)
            # Failure deliberately retains PUBLISHING for reconciliation on resume.
            url = (publisher or GitHubPublisher()).publish(pub['candidate'])
            pub.update(status='PR_CREATED', url=url, completed_at=time.time())
            with r.db:
                r.save('tasks', task)
            return pub


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', required=True)
    subs = parser.add_subparsers(dest='action', required=True)
    prepare = subs.add_parser('prepare')
    prepare.add_argument('task_id')
    prepare.add_argument('--title', required=True)
    prepare.add_argument('--body-file', required=True)
    prepare.add_argument('--base-branch', default='main')
    approve = subs.add_parser('approve')
    approve.add_argument('task_id')
    approve.add_argument('--packet-digest', required=True)
    approve.add_argument('--reviewer', required=True)
    subs.add_parser('resume').add_argument('task_id')
    args = vars(parser.parse_args())
    publication = Publication(LocalRunner(args.pop('state')))
    print(json.dumps(getattr(publication, args.pop('action'))(**args), indent=2))


if __name__ == '__main__':
    main()
