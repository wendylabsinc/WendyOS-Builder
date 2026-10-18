#!/usr/bin/env python3
"""Regression contracts for publishing an OS candidate before hardware verdicts."""
import re
import hashlib
import subprocess
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / '.github/workflows/build.yml').read_text()


def job(name):
    match = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [A-Za-z0-9_-]+:|\Z)',
                      WORKFLOW, re.M | re.S)
    if not match:
        raise AssertionError(f'missing job: {name}')
    return match.group(1)


def condition(body):
    match = re.search(r'^    if: >-\n((?:      .*\n)+)', body, re.M)
    if not match:
        raise AssertionError('gate must use an explicit multiline condition')
    return ' '.join(line.strip() for line in match.group(1).splitlines())


def allowed(expression, results, event='push', cancelled=False):
    expression = expression.replace('!cancelled()', repr(not cancelled))
    expression = expression.replace("github.event_name != 'pull_request'", repr(event != 'pull_request'))
    expression = re.sub(r"needs\.([a-z-]+)\.result == 'success'",
                        lambda m: repr(results.get(m[1]) == 'success'), expression)
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    if re.search(r'[^TrueFalsandor ()]', expression):
        raise AssertionError(f'unexpected gate expression: {expression}')
    return eval(expression, {'__builtins__': {}}, {})


class HardwareGateTest(unittest.TestCase):
    def test_every_incomplete_qualification_blocks_channel_promotion(self):
        body = job('promote')
        self.assertRegex(body, r'needs: \[[^\]]*hardware-qualification[^\]]*\]')
        expression = condition(body)
        results = dict.fromkeys(['build', 'publish', 'drivers', 'hardware-qualification'], 'success')
        self.assertTrue(allowed(expression, results))
        for dependency in results:
            for verdict in ['failure', 'skipped', 'cancelled', '']:
                with self.subTest(dependency=dependency, verdict=verdict):
                    self.assertFalse(allowed(expression, {**results, dependency: verdict}))
        self.assertFalse(allowed(expression, results, event='pull_request'))
        self.assertFalse(allowed(expression, results, cancelled=True))

    def test_announcements_wait_for_both_promotion_and_qualification(self):
        body = job('announce-qualified')
        expression = condition(body)
        self.assertTrue(allowed(expression, {'promote': 'success', 'hardware-qualification': 'success'}))
        self.assertFalse(allowed(expression, {'promote': 'failure', 'hardware-qualification': 'success'}))
        self.assertFalse(allowed(expression, {'promote': 'success', 'hardware-qualification': 'skipped'}))
        self.assertNotIn('gh release create', job('publish'))
        self.assertNotIn('git push', job('publish'))
        self.assertNotIn('DISCORD_', job('publish'))
        self.assertNotIn('git push origin "$VERSION" --force', body)

    def test_candidate_handoff_is_bound_to_this_build(self):
        body = job('hardware-qualification')
        for key, expression in {
            'source_ref': 'needs.detect-changes.outputs.integration-sha',
            'os_candidate_version': 'needs.detect-changes.outputs.version',
            'os_candidate_sha': 'needs.detect-changes.outputs.source-sha',
            'os_candidate_repository': 'github.repository',
            'os_candidate_run_id': 'github.run_id',
        }.items():
            self.assertIn(f'{key}: ${{{{ {expression} }}}}', body)
        self.assertIn('build_sha = $sha', job('build'))
        self.assertIn('build_storage = $storage', job('build'))
        self.assertEqual(WORKFLOW.count('ref: ${{ inputs.version }}'), 1)

    def test_stable_promotion_creates_only_a_draft_until_rebuild_qualifies(self):
        promote = (ROOT / '.github/workflows/promote.yml').read_text()
        self.assertIn('--draft', promote)
        self.assertNotIn('is out!', promote)
        self.assertIn('--ref "$TAG"', promote)
        self.assertIn('--draft=false', job('announce-qualified'))

    def test_image_stamp_hashes_actual_bundled_bytes_and_rejects_missing_agent(self):
        image = (ROOT / 'recipes-core/images/wendyos-image.bb').read_text()
        body = re.search(r'^stamp_bundled_agent\(\) \{\n(.*?)^\}', image, re.M | re.S)[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'opt/wendyos/bin/wendy-agent'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'fixture agent bytes')
            script = 'bbfatal() { return 1; }\n' + body.replace('${IMAGE_ROOTFS}', directory)
            result = subprocess.run(['/bin/sh', '-ec', script], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / 'usr/lib/wendyos/agent-sha256').read_text().strip(),
                             hashlib.sha256(binary.read_bytes()).hexdigest())
            binary.unlink()
            result = subprocess.run(['/bin/sh', '-ec', script], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_exact_runtime_build_and_agent_evidence_is_baked_into_image(self):
        recipe = (ROOT / 'recipes-core/wendyos-identity/wendyos-identity_1.0.bb').read_text()
        self.assertIn('echo "${WENDYOS_BUILD_VERSION}" > ${WORKDIR}/build-version', recipe)
        image = (ROOT / 'recipes-core/images/wendyos-image.bb').read_text()
        self.assertIn('stamp_bundled_agent;', image)
        self.assertIn('/usr/lib/wendyos/agent-sha256', image)


if __name__ == '__main__':
    unittest.main()
