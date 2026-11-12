#!/usr/bin/env python3
"""Evaluate the image-builder gates against fork, same-repo and push events."""
from pathlib import Path
import re
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / 'workflows/build.yml'


def condition(job):
    text = WORKFLOW.read_text()
    block = re.search(rf'^  {job}:\n(.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)', text, re.M | re.S)[1]
    return re.search(r'^    if: (.+)$', block, re.M)[1].removeprefix('${{').removesuffix('}}').strip()


def evaluate(expression, event, fork=False, cancelled=False, detected='success', devices='rpi4'):
    values = {'github.event_name': event, 'github.event.pull_request.head.repo.full_name':
              'outside/fork' if fork else 'wendylabsinc/WendyOS-Builder',
              'github.repository': 'wendylabsinc/WendyOS-Builder',
              'needs.detect-changes.result': detected, 'needs.detect-changes.outputs.devices': devices}
    for key in sorted(values, key=len, reverse=True):
        expression = expression.replace(key, repr(values[key]))
    expression = expression.replace('cancelled()', repr(cancelled)).replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression)
    return bool(eval(expression, {'__builtins__': {}}))


class BuilderSecurityTests(unittest.TestCase):
    def test_forks_never_reach_image_or_publishing_jobs(self):
        for name in ['detect-changes', 'build', 'publish-pr', 'drivers']:
            with self.subTest(job=name):
                self.assertFalse(evaluate(condition(name), 'pull_request', fork=True))

    def test_same_repository_prs_keep_image_and_driver_coverage(self):
        for name in ['detect-changes', 'build', 'publish-pr', 'drivers']:
            with self.subTest(job=name):
                self.assertTrue(evaluate(condition(name), 'pull_request'))

    def test_push_and_manual_builds_still_run(self):
        for event in ['push', 'workflow_dispatch']:
            for name in ['detect-changes', 'build', 'drivers']:
                self.assertTrue(evaluate(condition(name), event))
            self.assertFalse(evaluate(condition('publish-pr'), event))

    def test_no_driver_publishing_after_failed_or_skipped_detection(self):
        for result in ['failure', 'cancelled', 'skipped']:
            self.assertFalse(evaluate(condition('drivers'), 'pull_request', detected=result))
            self.assertFalse(evaluate(condition('publish-pr'), 'pull_request', detected=result))
        self.assertFalse(evaluate(condition('drivers'), 'pull_request', cancelled=True))

    def test_driver_only_pr_still_runs_drivers_without_os_build(self):
        self.assertFalse(evaluate(condition('build'), 'pull_request', devices=''))
        self.assertTrue(evaluate(condition('drivers'), 'pull_request', devices=''))

    def test_reusable_workflow_receives_only_named_cloud_secrets(self):
        text = WORKFLOW.read_text()
        self.assertNotIn('secrets: inherit', text)
        self.assertIn('GCP_WORKLOAD_IDENTITY_PROVIDER: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}', text)
        self.assertIn('GCP_SERVICE_ACCOUNT: ${{ secrets.GCP_SERVICE_ACCOUNT }}', text)


if __name__ == '__main__':
    unittest.main()
