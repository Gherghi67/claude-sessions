#!/usr/bin/env python3
# ABOUTME: Exercises Codex bootstrap protocol, exact identity, persistence, and cleanup.
# ABOUTME: Uses an isolated fake server and an optional real Codex no-model smoke test.

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / "bin/cs-codex-thread"
THREAD_ID = "01900000-0000-7000-8000-000000000001"
OTHER_ID = "01900000-0000-7000-8000-000000000002"
FAKE = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
root = Path(os.environ['FAKE_ROOT'])
mode = os.environ.get('FAKE_MODE', '')
count_file = root / 'count'
count = int(count_file.read_text()) + 1 if count_file.exists() else 1
count_file.write_text(str(count))
with (root / 'pids').open('a') as f: f.write(str(os.getpid()) + '\n')
if mode == 'stderr':
    os.write(2, b'private stderr value\x1b[2J\n' * 20000)
if mode == 'stubborn':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
for line in sys.stdin:
    request = json.loads(line)
    with (root / 'requests').open('a') as f:
        f.write(json.dumps({'process': count, 'cwd': os.getcwd(), 'request': request}) + '\n')
    method = request['method']
    if 'id' not in request: continue
    rid = request['id']
    def reply(value):
        print(json.dumps(dict(value, id=rid)), flush=True)
    if mode in ('timeout', 'stubborn'):
        time.sleep(60)
    if mode == 'eof': sys.exit(3)
    if mode == 'oversize':
        os.write(1, b'x' * (5 * 1024 * 1024)); time.sleep(60)
    if mode == 'server_request':
        print(json.dumps({'id': rid, 'method':'approval/request', 'params':{}}), flush=True)
        continue
    if mode == 'noise':
        print('not JSON startup output')
        print('[]')
        print(json.dumps({'method':'thread/started', 'params':{'thread':{'id':'wrong'}}}))
        print(json.dumps({'id':'unrelated', 'result':{'thread':{'id':'wrong'}}}))
    if mode == 'init_error' and method == 'initialize':
        reply({'error':{'code':-32600,'message':'private token secret\u001b[2J'}});continue
    if mode == 'active_writer' and method == 'thread/resume':
        reply({'error':{'code':-32600,'message':'private thread ID already has an active writer'}});continue
    if mode == 'inject_error' and method == 'thread/inject_items':
        reply({'error':{'code':-32601,'message':'unknown method'}});continue
    if mode == 'verify_error' and count == 2 and method == 'thread/resume':
        reply({'error':{'code':-32600,'message':'no rollout found'}});continue
    if mode == 'invalid_result':
        reply({'result':[]});continue
    if method in ('thread/start','thread/resume'):
        tid = '01900000-0000-7000-8000-000000000001'
        if mode == 'mismatch' and method == 'thread/resume':
            tid = '01900000-0000-7000-8000-000000000002'
        if mode == 'bad_id': tid = 'malicious\n--last'
        reply({'result':{'thread':{'id':tid,'ephemeral':mode == 'ephemeral'}}})
        if mode == 'write_timeout': time.sleep(60)
    else: reply({'result':{}})
if mode == 'cleanup':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(60)
'''


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cs-codex-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cwd = self.root / "project spaces 'quotes' $(touch UNEXPECTED) ;"
        self.cwd.mkdir()
        self.instructions = self.root / "context ' quoted.txt"
        self.instructions.write_text('CS context\n"quoted" \\ backslash ✓', encoding="utf-8")
        self.fake = self.root / "fake codex"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.env = dict(os.environ, FAKE_ROOT=str(self.root))

    def command(self, *extra):
        return [sys.executable, str(HELPER), '--codex-bin', str(self.fake),
                '--cwd', str(self.cwd), '--instructions-file', str(self.instructions),
                '--timeout', '5', *extra]

    def run_helper(self, mode='', *extra):
        result = subprocess.run(self.command(*extra), env=dict(self.env, FAKE_MODE=mode),
                                capture_output=True, text=True, timeout=10)
        self.assert_cleaned_up()
        return result

    def assert_cleaned_up(self):
        path = self.root / 'pids'
        if path.exists():
            for pid in path.read_text().splitlines():
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid), 0)

    def requests(self):
        path = self.root / 'requests'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_failure(self, mode, text, *extra):
        result = self.run_helper(mode, *extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn(text, result.stderr)
        return result

    def test_new_thread_persists_in_fresh_process_and_preserves_context(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, THREAD_ID + '\n')
        self.assertEqual(result.stderr, '')
        requests = self.requests()
        self.assertEqual([r['request']['method'] for r in requests], [
            'initialize', 'initialized', 'thread/start', 'thread/inject_items',
            'thread/unsubscribe', 'initialize', 'initialized', 'thread/resume', 'thread/unsubscribe'])
        self.assertEqual({r['process'] for r in requests}, {1, 2})
        for record in requests:
            self.assertEqual(Path(record['cwd']).resolve(), self.cwd.resolve())
            params = record['request'].get('params', {})
            self.assertNotIn('developerInstructions', params)
            self.assertNotIn('config', params)
        start = requests[2]['request']['params']
        self.assertEqual(start, {'cwd': str(self.cwd.resolve()), 'ephemeral': False})
        injection = requests[3]['request']['params']
        self.assertEqual(injection['threadId'], THREAD_ID)
        self.assertEqual(injection['items'], [{'type': 'message', 'role': 'developer',
                          'content': [{'type': 'input_text', 'text': self.instructions.read_text()}]}])
        self.assertFalse((self.cwd / 'UNEXPECTED').exists())

    def test_existing_thread_refresh_does_not_create_or_inject_twice(self):
        result = self.run_helper('', '--thread-id', THREAD_ID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, THREAD_ID + '\n')
        methods = [r['request']['method'] for r in self.requests()]
        self.assertNotIn('thread/start', methods)
        self.assertEqual(methods.count('thread/resume'), 2)
        self.assertEqual(methods.count('thread/inject_items'), 1)

    def test_noise_and_wrong_ids_cannot_supply_thread_identity(self):
        result = self.run_helper('noise')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, THREAD_ID + '\n')

    def test_large_private_stderr_does_not_block_or_leak(self):
        result = self.run_helper('stderr')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_rpc_error_redacts_server_message(self):
        result = self.assert_failure('init_error', 'rejected initialize (code -32600)')
        self.assertNotIn('secret', result.stderr)
        self.assertNotIn('\x1b', result.stderr)

    def test_active_writer_has_actionable_redacted_error(self):
        result = self.assert_failure('active_writer', 'close the existing Codex CLI or desktop session',
                                     '--thread-id', THREAD_ID)
        self.assertNotIn('private thread ID', result.stderr)
        self.assertNotIn('thread/start', [r['request']['method'] for r in self.requests()])

    def test_unsupported_injection_is_actionable(self):
        self.assert_failure('inject_error', 'experimental API support')

    def test_failed_persistence_never_returns_id(self):
        self.assert_failure('verify_error', 'rejected thread/resume')

    def test_changed_identity_never_falls_back(self):
        self.assert_failure('mismatch', 'different thread', '--thread-id', THREAD_ID)
        self.assertNotIn('thread/start', [r['request']['method'] for r in self.requests()])

    def test_malformed_id_is_rejected(self):
        self.assert_failure('bad_id', 'exact thread ID')

    def test_ephemeral_thread_is_rejected(self):
        self.assert_failure('ephemeral', 'ephemeral thread')

    def test_invalid_result_is_rejected(self):
        self.assert_failure('invalid_result', 'invalid initialize response')

    def test_server_interactions_are_not_approved(self):
        self.assert_failure('server_request', 'unsupported interaction')

    def test_early_exit(self):
        # The server's own output stays private; its exit status is not.
        self.assert_failure('eof', 'exited before completing bootstrap (exit status 3)')

    def test_missing_codex_home_is_named_without_launching(self):
        missing = self.root / 'no such home'
        result = subprocess.run(self.command(), env=dict(self.env, CODEX_HOME=str(missing)),
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('CODEX_HOME points to ' + str(missing), result.stderr)
        self.assertFalse((self.root / 'count').exists(), 'the server must not start')

    def test_response_timeout_is_bounded_and_process_reaped(self):
        started = time.monotonic()
        self.assert_failure('timeout', 'timed out', '--timeout', '0.15')
        self.assertLess(time.monotonic() - started, 4)

    def test_blocked_stdin_does_not_defeat_timeout(self):
        self.instructions.write_text('x' * 200000)
        self.assert_failure('write_timeout', 'timed out', '--timeout', '0.15')

    def test_oversized_output_is_bounded(self):
        self.assert_failure('oversize', 'protocol limit')

    def test_sigterm_ignoring_server_is_killed(self):
        self.assert_failure('stubborn', 'timed out', '--timeout', '0.15')

    def test_cleanup_after_success_can_kill_a_stubborn_server(self):
        result = self.run_helper('cleanup')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_interrupt_cleans_up_server(self):
        process = subprocess.Popen(self.command(), env=dict(self.env, FAKE_MODE='timeout'),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 3
            while not (self.root / 'pids').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / 'pids').exists())
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130)
            self.assertEqual(stdout, '')
            self.assertIn('interrupted', stderr)
            self.assert_cleaned_up()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_bad_arguments_and_empty_inputs_do_not_launch_server(self):
        for extra in [('--thread-id', '--last'), ('--timeout', 'nan'), ('--timeout', '0')]:
            result = self.run_helper('', *extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
        self.instructions.write_text('')
        self.assert_failure('', 'must not be empty')
        self.assertFalse((self.root / 'pids').exists())

    @unittest.skipUnless(os.environ.get('CS_CODEX_REAL_BIN'), 'set CS_CODEX_REAL_BIN for no-model smoke test')
    def test_real_codex_persists_context_without_a_model_turn(self):
        home = self.root / 'isolated-codex-home'
        home.mkdir()
        (home / 'config.toml').write_text(
            'model = "gpt-5.5"\ndeveloper_instructions = "USER_CONFIGURATION_MARKER"\n'
            '[analytics]\nenabled = false\n')
        env = dict(os.environ, CODEX_HOME=str(home))
        command = [sys.executable, str(HELPER), '--codex-bin', os.environ['CS_CODEX_REAL_BIN'],
                   '--cwd', str(self.cwd), '--instructions-file', str(self.instructions)]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stderr)
        thread_id = result.stdout.strip()
        self.assertRegex(thread_id, r'^[a-f0-9-]{36}$')
        rollouts = list(home.glob('sessions/**/*.jsonl'))
        self.assertEqual(len(rollouts), 1)
        contents = [json.loads(line) for line in rollouts[0].read_text().splitlines()]
        self.assertEqual(contents[0]['payload']['id'], thread_id)
        developer_text = '\n'.join(c.get('text', '') for item in contents
                                  if item.get('payload', {}).get('role') == 'developer'
                                  for c in item['payload'].get('content', []))
        self.assertIn('USER_CONFIGURATION_MARKER', developer_text)
        self.assertIn(self.instructions.read_text(), developer_text)
        self.assertFalse(any(item.get('payload', {}).get('type') == 'task_started' for item in contents))
        self.instructions.write_text('CS refreshed context marker')
        refresh = subprocess.run(command + ['--thread-id', thread_id], env=env,
                                 capture_output=True, text=True, timeout=40)
        self.assertEqual(refresh.returncode, 0, refresh.stderr)
        self.assertEqual(refresh.stdout, thread_id + '\n')
        self.assertIn('CS refreshed context marker', rollouts[0].read_text())


if __name__ == '__main__':
    unittest.main()
