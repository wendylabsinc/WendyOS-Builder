#!/usr/bin/env python3
"""Hold the CI trust boundaries: which events and jobs may reach runners, tokens and secrets."""
import os
from pathlib import Path
import re
import subprocess
import unittest

import yaml

WORKFLOWS = Path(__file__).resolve().parents[1] / 'workflows'
REPOSITORY = 'wendylabsinc/WendyOS-Builder'
SAME_REPOSITORY = 'github.event.pull_request.head.repo.full_name == github.repository'
NOT_DEPENDABOT = "github.actor != 'dependabot[bot]'"
NOT_A_PULL_REQUEST = "github.event_name != 'pull_request'"
# The only condition that lets an event into the image, publish and driver jobs.
BUILD_GATE = ("github.event_name == 'push' || github.event_name == 'workflow_dispatch' || "
              f"(github.event_name == 'pull_request' && {SAME_REPOSITORY} && {NOT_DEPENDABOT})")
# A new trigger needs a decision here first: these never run code from a fork with a token.
TRIGGERS = {'push', 'pull_request', 'workflow_dispatch', 'workflow_call', 'schedule'}
# Jobs that push tags or releases with the checkout's own credentials.
PUSHES_WITH_CHECKOUT_TOKEN = {('build.yml', 'publish'), ('promote.yml', 'promote')}
STATUS_FUNCTION = re.compile(r'\b(always|cancelled|failure|success)\(\)')


def load(name):
    document = yaml.safe_load((WORKFLOWS / name).read_text())
    # YAML 1.1 reads the bare key `on` as the boolean true.
    triggers = document.get('on', document.get(True))
    if not isinstance(triggers, dict):
        triggers = dict.fromkeys([triggers] if isinstance(triggers, str) else triggers)
    return document, triggers


WORKFLOW_FILES = sorted(path.name for path in WORKFLOWS.glob('*.y*ml'))
LOADED = {name: load(name) for name in WORKFLOW_FILES}
TRIGGERS_OF = {name: set(LOADED[name][1]) for name in WORKFLOW_FILES}
JOBS = [(name, job, body) for name in WORKFLOW_FILES for job, body in LOADED[name][0]['jobs'].items()]


def condition(body):
    text = ' '.join(str(body.get('if', '')).split())
    return text.removeprefix('${{').removesuffix('}}').strip()


def conjuncts(expression):
    """Terms that must all hold; none when a top-level || could bypass any of them."""
    terms, depth, start, index = [], 0, 0, 0
    while index < len(expression):
        char = expression[index]
        depth += (char == '(') - (char == ')')
        if depth == 0 and expression.startswith('||', index):
            return []
        if depth == 0 and expression.startswith('&&', index):
            terms.append(expression[start:index].strip())
            start = index + 2
            index += 1
        index += 1
    return terms + [expression[start:].strip()]


def needs(body):
    value = body.get('needs', [])
    return [value] if isinstance(value, str) else value


def github_hosted(body):
    # The exact label form: a self-hosted runner may carry any other label.
    return bool(re.fullmatch(r'(ubuntu|macos|windows)-(latest|\d+(\.\d+)?)', str(body.get('runs-on'))))


def privileged(name, body):
    """A job that fork code must never reach: own runner, write token, secrets or a called workflow."""
    permissions = body.get('permissions', LOADED[name][0].get('permissions'))
    write = not isinstance(permissions, dict) or 'write' in permissions.values()
    return 'uses' in body or not github_hosted(body) or write or 'secrets.' in yaml.safe_dump(body)


def trusted(name, job, seen=()):
    """Whether a job can only run for an event the build gate would also accept."""
    jobs = LOADED[name][0]['jobs']
    body, expression = jobs[job], condition(jobs[job])
    terms = conjuncts(expression)
    if 'pull_request' not in TRIGGERS_OF[name] or expression == BUILD_GATE:
        return True
    if NOT_A_PULL_REQUEST in terms or {SAME_REPOSITORY, NOT_DEPENDABOT} <= set(terms):
        return True
    if job in seen:
        return False
    if not STATUS_FUNCTION.search(expression):
        # Implicit success(): every needed job succeeded, so one trusted ancestor is enough.
        return any(trusted(name, parent, seen + (job,)) for parent in needs(body))
    succeeded = [re.fullmatch(r"needs\.([\w-]+)\.result == 'success'", term) for term in terms]
    return any(match and match[1] in needs(body) and trusted(name, match[1], seen + (job,)) for match in succeeded)


def steps(body, action):
    return [step for step in body.get('steps', []) if str(step.get('uses', '')).startswith(action + '@')]


def evaluate(expression, event, fork=False, actor='maintainer', cancelled=False, detected='success', devices='rpi4'):
    values = {'github.event_name': event, 'github.actor': actor,
              'github.event.pull_request.head.repo.full_name': 'outside/fork' if fork else REPOSITORY,
              'github.repository': REPOSITORY, 'needs.publish.result': detected,
              'needs.detect-changes.result': detected, 'needs.detect-changes.outputs.devices': devices}
    # GitHub adds success() to a condition that names no status function.
    implicit = not STATUS_FUNCTION.search(expression)
    expression = expression or 'True'
    status = {'always()': True, 'cancelled()': cancelled, 'success()': detected == 'success',
              'failure()': detected == 'failure'}
    for key, value in list(values.items()) + list(status.items()):
        expression = expression.replace(key, repr(value))
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression)
    # The input is this repository's own workflow text, evaluated without builtins.
    return bool(eval(expression, {'__builtins__': {}})) and (not implicit or detected == 'success')


BUILD_JOBS = LOADED['build.yml'][0]['jobs']
GATED = [job for job in BUILD_JOBS if job != 'required-ci']


def runs(job, event, fork=False, actor='maintainer', **state):
    """Whether a build.yml job runs, given that every gated job needs detect-changes."""
    if not evaluate(condition(BUILD_JOBS['detect-changes']), event, fork, actor):
        return job != 'detect-changes' and evaluate(condition(BUILD_JOBS[job]), event, fork, actor, detected='skipped')
    return evaluate(condition(BUILD_JOBS[job]), event, fork, actor, **state)


class TrustBoundaryTests(unittest.TestCase):
    """Rules over every workflow and job, so a new one cannot quietly miss them."""

    def test_only_reviewed_triggers_are_used(self):
        for name in WORKFLOW_FILES:
            with self.subTest(workflow=name):
                self.assertLessEqual(TRIGGERS_OF[name], TRIGGERS)

    def test_pushes_are_trusted_only_from_main_and_release_tags(self):
        for name in WORKFLOW_FILES:
            if 'push' in TRIGGERS_OF[name]:
                with self.subTest(workflow=name):
                    push = LOADED[name][1]['push'] or {}
                    self.assertEqual(push.get('branches'), ['main'])
                    self.assertIn(push.get('tags'), [None, ['[0-9]+.[0-9]+.[0-9]+']])

    def test_every_job_declares_its_token_permissions(self):
        for name, job, body in JOBS:
            with self.subTest(workflow=name, job=job):
                # A mapping, not the write-all or read-all shorthand.
                self.assertIsInstance(body.get('permissions', LOADED[name][0].get('permissions')), dict)

    def test_privileged_jobs_never_run_for_untrusted_code(self):
        for name, job, body in JOBS:
            if privileged(name, body):
                with self.subTest(workflow=name, job=job):
                    self.assertTrue(trusted(name, job))

    def test_reusable_workflows_have_no_trigger_of_their_own(self):
        called = {name for name in WORKFLOW_FILES if 'workflow_call' in TRIGGERS_OF[name]}
        for name in called:
            with self.subTest(workflow=name):
                self.assertLessEqual(TRIGGERS_OF[name], {'workflow_call', 'workflow_dispatch'})
        for name, job, body in JOBS:
            if 'uses' in body:
                with self.subTest(workflow=name, job=job):
                    self.assertIn(body['uses'].removeprefix('./.github/workflows/'), called)
                    self.assertNotEqual(body.get('secrets'), 'inherit')

    def test_checkouts_keep_no_credentials_unless_the_job_pushes(self):
        for name, job, body in JOBS:
            for step in steps(body, 'actions/checkout'):
                with self.subTest(workflow=name, job=job):
                    kept = step.get('with', {}).get('persist-credentials') is not False
                    self.assertEqual(kept, (name, job) in PUSHES_WITH_CHECKOUT_TOKEN)

    def test_privileged_jobs_restore_no_shared_cache(self):
        for name, job, body in JOBS:
            if not privileged(name, body):
                continue
            for step in body.get('steps', []):
                action = str(step.get('uses', '')).split('@')[0]
                with self.subTest(workflow=name, job=job, action=action):
                    self.assertFalse(action.startswith('actions/cache'))
                    # setup-go caches unless told not to; the other setup actions only when asked.
                    default = action == 'actions/setup-go'
                    self.assertFalse(step.get('with', {}).get('cache', default))

    def test_actions_are_pinned_to_a_commit_named_by_its_release(self):
        for name in WORKFLOW_FILES:
            for line in (WORKFLOWS / name).read_text().splitlines():
                if re.match(r'\s*(- )?uses: (?!\./)', line):
                    with self.subTest(workflow=name, line=line.strip()):
                        self.assertRegex(line, r'uses: [\w./-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+$')


class BuildGateTests(unittest.TestCase):
    """The gate's behaviour, event by event."""

    def test_forks_never_reach_image_or_publishing_jobs(self):
        for name in GATED:
            with self.subTest(job=name):
                self.assertFalse(runs(name, 'pull_request', fork=True))

    def test_dependabot_updates_build_only_after_a_maintainer_pushes(self):
        for name in GATED:
            with self.subTest(job=name):
                self.assertFalse(runs(name, 'pull_request', actor='dependabot[bot]'))
        self.assertTrue(runs('build', 'pull_request', actor='maintainer'))

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
            for name, event in [('build', 'pull_request'), ('drivers', 'pull_request'),
                                ('publish-pr', 'pull_request'), ('publish', 'push')]:
                self.assertFalse(evaluate(condition(BUILD_JOBS[name]), event, detected=result))
        self.assertFalse(evaluate(condition(BUILD_JOBS['drivers']), 'pull_request', cancelled=True))

    def test_driver_only_pr_still_runs_drivers_without_os_build(self):
        self.assertFalse(runs('build', 'pull_request', devices=''))
        self.assertTrue(runs('drivers', 'pull_request', devices=''))

    def test_required_check_explains_a_skipped_build_and_still_fails(self):
        job = BUILD_JOBS['required-ci']
        self.assertEqual(condition(job), 'always()')
        self.assertFalse(privileged('build.yml', job))
        script = job['steps'][0]['run']

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
        self.assertEqual(BUILD_JOBS['drivers']['secrets'], {
            'GCP_WORKLOAD_IDENTITY_PROVIDER': '${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}',
            'GCP_SERVICE_ACCOUNT': '${{ secrets.GCP_SERVICE_ACCOUNT }}'})


if __name__ == '__main__':
    unittest.main()
