import copy
import os
import re
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('DAIMON_TEST_SOURCE', ROOT / 'linux-toolbox.sh')).read_text(encoding='utf-8')
PROGRAM = re.search(r"<<'PYSSH_TXN'\n(.*?)\nPYSSH_TXN", SOURCE, re.S).group(1)


def worker():
    module = types.ModuleType('ssh_transaction_test')
    exec(compile(PROGRAM, 'ssh-transaction-worker', 'exec'), module.__dict__)
    return module


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.w = worker()

    def test_preserve_match(self):
        original = 'PasswordAuthentication yes\nMatch User another\n    PasswordAuthentication yes\n'
        result, desired = self.w.candidate(original, [('PasswordAuthentication', 'no')])
        self.assertTrue(result.endswith(original))
        self.assertEqual(desired, {'passwordauthentication': 'no'})
        self.assertLess(result.index('PasswordAuthentication no'), result.index('Match'))

    def test_insert_before_include_and_match(self):
        for original in ('Include /etc/ssh/sshd_config.d/*.conf\n', 'Match User another\n'):
            result, _ = self.w.candidate(original, [('PubkeyAuthentication', 'no')])
            self.assertTrue(result.endswith(original))
            self.assertLess(result.index('PubkeyAuthentication no'), result.index(original))

    def test_idempotence_and_alias(self):
        changes = [('ChallengeResponseAuthentication', 'no'), ('PermitRootLogin', 'without-password')]
        first, desired = self.w.candidate('Port 22\n', changes)
        second, _ = self.w.candidate(first, changes)
        self.assertEqual(first, second)
        self.assertEqual(desired['kbdinteractiveauthentication'], 'no')
        self.assertEqual(desired['permitrootlogin'], 'prohibit-password')

    def test_main_port_replacement(self):
        result, _ = self.w.candidate('Port 22\n  port 23\nInclude ports.conf\n', [('Port', '002224')])
        self.assertIn('Port 2224\n', result)
        self.assertNotIn('Port 22\n', result)
        self.assertNotIn('port 23', result)
        self.assertIn('Include ports.conf', result)

    def test_reject_invalid_options(self):
        for changes in ([('Port', '0')], [('Port', '65536')], [('Port', '２２')],
                        [('Port', '22\nPermitRootLogin yes')], [('Unknown', 'yes')],
                        [('AuthorizedKeysFile', '/tmp/keys')], [('PasswordAuthentication', 'maybe')]):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.w.candidate('', changes)

    def test_reject_corrupt_managed_block(self):
        for body in ('Port 22\n', 'Port 22\nPort 23\n' + self.w.END + '\n',
                     'BadOption yes\n' + self.w.END + '\n'):
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.w.candidate(self.w.BEGIN + '\n' + body, [('Port', '2224')])

    def test_effective_conflict_rejected(self):
        with self.assertRaises(ValueError):
            self.w.check_policy({'port': ['22', '2224']}, {'port': '2224'})
        self.w.check_policy({'permitrootlogin': ['without-password']}, {'permitrootlogin': 'prohibit-password'})


class ConfirmationTests(unittest.TestCase):
    def setUp(self):
        self.w = worker()
        self.state = {'token': 'a' * 32, 'boot_id': 'same-boot', 'deadline': 200, 'started': 50,
                      'connection': '192.0.2.1 1000 192.0.2.2 22', 'ports': ['22'],
                      'service': 'ssh.service', 'candidate_hash': self.w.digest(b'candidate'),
                      'desired': {'pubkeyauthentication': 'yes'}}
        self.connection = '192.0.2.1 1001 192.0.2.2 22'
        self.w.CONFIG = Mock()
        self.w.CONFIG.read_bytes.return_value = b'candidate'
        self.w.boot_id = Mock(return_value='same-boot')
        self.w.ssh_session_started = Mock(return_value=75)
        self.w.preflight_service = Mock(return_value='ssh.service')
        self.w.trusted_file = Mock()
        self.w.effective = Mock(return_value={'pubkeyauthentication': ['yes']})
        self.w.root_authentication_available = Mock()
        self.w.cleanup = Mock()
        self.clock = patch.object(self.w.time, 'monotonic', return_value=100)
        self.clock.start()
        self.addCleanup(self.clock.stop)

    def invoke(self, token=None):
        with patch.dict(os.environ, {'SSH_CONNECTION': self.connection}):
            self.w.confirm(copy.deepcopy(self.state), token or self.state['token'])

    def test_accept_new_connection(self):
        self.invoke()
        self.w.cleanup.assert_called_once_with(self.state)

    def test_reject_old_connection(self):
        self.connection = self.state['connection']
        with self.assertRaises(ValueError):
            self.invoke()
        self.w.cleanup.assert_not_called()

    def test_reject_wrong_token(self):
        with self.assertRaises(ValueError):
            self.invoke('b' * 32)
        self.w.cleanup.assert_not_called()

    def test_reject_other_preexisting_session(self):
        self.w.ssh_session_started.return_value = 49
        with self.assertRaises(ValueError):
            self.invoke()
        self.w.cleanup.assert_not_called()

    def test_reject_wrong_port(self):
        self.connection = '192.0.2.1 1001 192.0.2.2 2224'
        with self.assertRaises(ValueError):
            self.invoke()
        self.w.cleanup.assert_not_called()

    def test_reject_expired_or_rebooted(self):
        self.state['deadline'] = 100
        with self.assertRaises(ValueError):
            self.invoke()
        self.state['deadline'] = 200
        self.w.boot_id.return_value = 'other-boot'
        with self.assertRaises(ValueError):
            self.invoke()
        self.w.cleanup.assert_not_called()

    def test_reject_external_change(self):
        self.w.CONFIG.read_bytes.return_value = b'external'
        with self.assertRaises(ValueError):
            self.invoke()
        self.w.cleanup.assert_not_called()

    def test_reject_effective_policy_change(self):
        self.w.effective.return_value = {'pubkeyauthentication': ['no']}
        with self.assertRaises(ValueError):
            self.invoke()
        self.w.cleanup.assert_not_called()


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.w = worker()
        self.w.CONFIG = Mock()
        self.w.CONFIG.read_bytes.return_value = b'candidate'
        self.w.PENDING = Mock()
        self.original = Mock()
        self.original.read_bytes.return_value = b'original'
        self.w.PENDING = MockPath(self.original)
        self.w.trusted_file = Mock()
        self.w.command = Mock()
        self.w.atomic_write = Mock()
        self.w.service_properties = Mock(return_value={'ActiveState': 'inactive'})
        self.w.preflight_service = Mock(return_value='ssh.service')
        self.w.cleanup = Mock()
        self.state = {'original_hash': self.w.digest(b'original'), 'candidate_hash': self.w.digest(b'candidate'),
                      'metadata': [0o600, 0, 0], 'service': 'ssh.service'}

    def test_inactive_service_not_started(self):
        self.w.recover(self.state)
        self.w.atomic_write.assert_called_once_with(self.w.CONFIG, b'original', 0o600, 0, 0)
        self.assertEqual(self.w.command.call_count, 1)
        self.w.cleanup.assert_called_once()

    def test_unknown_config_never_overwritten(self):
        self.w.CONFIG.read_bytes.return_value = b'external'
        with self.assertRaises(ValueError):
            self.w.recover(self.state)
        self.w.atomic_write.assert_not_called()
        self.w.cleanup.assert_not_called()

    def test_reload_failure_retains_recovery_material(self):
        self.w.service_properties.return_value = {'ActiveState': 'active'}
        self.w.command.side_effect = ['', ValueError('reload failed')]
        with self.assertRaises(ValueError):
            self.w.recover(self.state)
        self.w.atomic_write.assert_called_once()
        self.w.cleanup.assert_not_called()

    def test_reloading_service_not_treated_as_inactive(self):
        self.w.service_properties.side_effect = [{'ActiveState': 'reloading'}, {'ActiveState': 'active'},
                                                 {'ActiveState': 'active'}]
        with patch.object(self.w.time, 'sleep'):
            self.w.recover(self.state)
        self.w.command.assert_any_call('/usr/bin/systemctl', 'reload', 'ssh.service')
        self.w.cleanup.assert_called_once()


class MockPath:
    def __init__(self, child):
        self.child = child

    def __truediv__(self, name):
        if name != 'original':
            raise AssertionError(name)
        return self.child


if __name__ == '__main__':
    unittest.main()
