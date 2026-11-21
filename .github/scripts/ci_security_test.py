#!/usr/bin/env python3
"""Evaluate the image-builder gates against fork, same-repo and push events."""
import os
from pathlib import Path
import re
import subprocess
import textwrap
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / 'workflows/build.yml'


def job_block(job):
    return re.search(rf'^  {job}:\n(.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)', WORKFLOW.read_text(), re.M | re.S)[1]


def condition(job):
    lines = job_block(job).split('\n')
    start = next(i for i, line in enumerate(lines) if line.startswith('    if:'))
    parts = [lines[start][len('    if:'):].strip().lstrip('>-')]
    for line in lines[start + 1:]:
        if not line.startswith('      '):
            break
        parts.append(line.strip())
    return ' '.join(parts).strip().removeprefix('${{').removesuffix('}}').strip()


def evaluate(expression, event, fork=False, cancelled=False, detected='success', devices='rpi4'):
    values = {'github.event_name': event, 'github.event.pull_request.head.repo.full_name':
              'outside/fork' if fork else 'wendylabsinc/WendyOS-Builder',
              'github.repository': 'wendylabsinc/WendyOS-Builder',
              'needs.detect-changes.result': detected, 'needs.detect-changes.outputs.devices': devices}
    # GitHub adds success() to a condition that names no status function.
    implicit = not re.search(r'\b(always|cancelled|failure|success)\(\)', expression)
    for key in sorted(values, key=len, reverse=True):
        expression = expression.replace(key, repr(values[key]))
    expression = expression.replace('cancelled()', repr(cancelled)).replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression)
    return bool(eval(expression, {'__builtins__': {}})) and (not implicit or detected == 'success')


def runs(job, event, fork=False, **state):
    """Whether a job runs, given that every gated job needs detect-changes."""
    if not evaluate(condition('detect-changes'), event, fork, detected='success'):
        return job != 'detect-changes' and evaluate(condition(job), event, fork, detected='skipped')
    return evaluate(condition(job), event, fork, **state)


GATED = ['detect-changes', 'build', 'publish', 'publish-pr', 'drivers']


class BuilderSecurityTests(unittest.TestCase):
    def test_forks_never_reach_image_or_publishing_jobs(self):
        for name in GATED:
            with self.subTest(job=name):
                self.assertFalse(runs(name, 'pull_request', fork=True))

    def test_unlisted_events_never_reach_image_or_publishing_jobs(self):
        for event in ['pull_request_target', 'workflow_run', 'issue_comment', 'pull_request_review', 'schedule']:
            for fork in [False, True]:
                for name in GATED:
                    with self.subTest(event=event, fork=fork, job=name):
                        self.assertFalse(runs(name, event, fork=fork))

    def test_same_repository_prs_keep_image_and_driver_coverage(self):
        for name in ['detect-changes', 'build', 'publish-pr', 'drivers']:
            with self.subTest(job=name):
                self.assertTrue(runs(name, 'pull_request'))
        self.assertFalse(runs('publish', 'pull_request'))

    def test_push_and_manual_builds_still_run(self):
        for event in ['push', 'workflow_dispatch']:
            for name in ['detect-changes', 'build', 'publish', 'drivers']:
                self.assertTrue(runs(name, event))
            self.assertFalse(runs('publish-pr', event))

    def test_no_publishing_after_failed_or_skipped_detection(self):
        for result in ['failure', 'cancelled', 'skipped']:
            self.assertFalse(evaluate(condition('build'), 'pull_request', detected=result))
            self.assertFalse(evaluate(condition('drivers'), 'pull_request', detected=result))
            self.assertFalse(evaluate(condition('publish-pr'), 'pull_request', detected=result))
            self.assertFalse(evaluate(condition('publish'), 'push', detected=result))
        self.assertFalse(evaluate(condition('drivers'), 'pull_request', cancelled=True))

    def test_driver_only_pr_still_runs_drivers_without_os_build(self):
        self.assertFalse(runs('build', 'pull_request', devices=''))
        self.assertTrue(runs('drivers', 'pull_request', devices=''))

    def test_required_check_explains_a_skipped_build_and_still_fails(self):
        self.assertIn("if: ${{ always() }}", job_block('required-ci'))
        script = textwrap.dedent(re.search(r'^        run: \|\n((?:          .*\n|\n)+)', job_block('required-ci'), re.M)[1])

        def check(detect, build, devices):
            env = {'PATH': os.environ['PATH'], 'DETECT_RESULT': detect, 'BUILD_RESULT': build, 'DEVICES': devices}
            return subprocess.run(['bash', '-e', '-c', script], env=env, capture_output=True, text=True)

        skipped = check('skipped', 'skipped', '')
        self.assertNotEqual(skipped.returncode, 0)
        self.assertIn('::error::', skipped.stdout)
        self.assertEqual(check('success', 'success', 'rpi4').returncode, 0)
        self.assertEqual(check('success', 'skipped', '').returncode, 0)
        for detect, build, devices in [('failure', 'skipped', ''), ('success', 'failure', 'rpi4'),
                                       ('success', 'skipped', 'rpi4'), ('success', 'cancelled', 'rpi4')]:
            self.assertNotEqual(check(detect, build, devices).returncode, 0)

    def test_reusable_workflow_receives_only_named_cloud_secrets(self):
        text = WORKFLOW.read_text()
        self.assertNotIn('secrets: inherit', text)
        self.assertIn('GCP_WORKLOAD_IDENTITY_PROVIDER: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}', text)
        self.assertIn('GCP_SERVICE_ACCOUNT: ${{ secrets.GCP_SERVICE_ACCOUNT }}', text)


if __name__ == '__main__':
    unittest.main()
