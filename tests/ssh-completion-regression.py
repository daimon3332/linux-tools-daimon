import importlib.util
import unittest
from unittest.mock import Mock
from pathlib import Path

spec = importlib.util.spec_from_file_location('transaction_tests', Path(__file__).with_name('ssh-transaction-regression.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Completion(unittest.TestCase):
    def setUp(self):
        self.w = module.worker()

    def test_key_delete_preserves_other_bytes(self):
        body = b'# heading\nssh-ed25519 first first-key\nssh-ed25519 second second-key\n'
        self.assertEqual(self.w.key_candidate(body, '2'), b'# heading\nssh-ed25519 second second-key\n')

    def test_invalid_key_selection_rejected(self):
        for number in ('0', '-1', '2', 'abc', '1;id'):
            with self.subTest(number=number), self.assertRaises(ValueError):
                self.w.key_candidate(b'ssh-ed25519 only key\n', number)

    def test_key_comment_not_a_deletion_target(self):
        with self.assertRaises(ValueError):
            self.w.key_candidate(b'# heading\nssh-ed25519 second key\n', '1')

    def test_last_public_key_is_never_deleted(self):
        with self.assertRaises(ValueError):
            self.w.key_candidate(b'ssh-ed25519 only key\n# comment\n', '1')

    def test_ufw_adds_only_missing_ports_and_retains_baseline(self):
        self.w.ufw_snapshot = Mock(return_value={'active': True, 'rules': [['allow', '64400/tcp']], 'config': {}})
        fw = self.w.firewall_plan(['64400'], ['64401'], False, 'a' * 32)
        self.assertEqual(fw['ports'], ['64401'])
        self.assertEqual(fw['baseline']['rules'], [['allow', '64400/tcp']])

    def test_existing_allow_rule_not_relabelled(self):
        self.w.ufw_snapshot = Mock(return_value={'active': True, 'rules': [['allow', '64400/tcp', 'comment', 'business']], 'config': {}})
        fw = self.w.firewall_plan(['64400'], ['64400'], True, 'a' * 32)
        self.assertEqual(fw['ports'], [])

    def test_ufw_external_rules_block_owned_cleanup(self):
        baseline = {'active': True, 'rules': [['allow', '64400/tcp']], 'config': {}}
        self.w.ufw_snapshot = Mock(return_value=dict(baseline, rules=baseline['rules'] + [['deny', '80/tcp']]))
        fw = {'baseline': baseline, 'ports': ['64401'], 'tag': 'daimon-ssh-' + 'a' * 32, 'enable': False}
        self.w.command = Mock()
        with self.assertRaises(ValueError):
            self.w.firewall_restore(fw)
        self.w.command.assert_not_called()

    def test_inactive_ufw_not_enabled_implicitly(self):
        self.w.ufw_snapshot = Mock(return_value={'active': False, 'rules': [], 'config': {}})
        self.assertIsNone(self.w.firewall_plan(['22'], ['2224'], False, 'a' * 32))
        with self.assertRaises(ValueError):
            self.w.firewall_plan(['22'], ['2224'], True, 'a' * 32)

    def test_partial_firewall_apply_removes_only_owned_rule(self):
        tag = 'daimon-ssh-' + 'a' * 32
        baseline = {'active': True, 'rules': [['deny', '22/tcp']], 'config': {}}
        owned = ['allow', '2224/tcp', 'comment', tag]
        self.w.ufw_snapshot = Mock(side_effect=[dict(baseline, rules=[owned] + baseline['rules']), baseline])
        self.w.command = Mock()
        self.w.firewall_restore({'baseline': baseline, 'ports': ['2224', '2225'], 'tag': tag})
        self.w.command.assert_called_once_with('/usr/sbin/ufw', '--force', 'delete', *owned)

    def test_boot_can_remove_owned_persistent_rules_before_ufw_start(self):
        tag = 'daimon-ssh-' + 'a' * 32
        baseline = {'active': True, 'rules': [['allow', '22/tcp']], 'config': {}}
        owned = ['allow', '2224/tcp', 'comment', tag]
        self.w.ufw_snapshot = Mock(side_effect=[dict(baseline, active=False, rules=[owned] + baseline['rules']), dict(baseline, active=False)])
        self.w.command = Mock()
        self.w.firewall_restore({'baseline': baseline, 'ports': ['2224'], 'tag': tag}, boot=True)
        self.w.command.assert_called_once_with('/usr/sbin/ufw', '--force', 'delete', *owned)

    def test_missing_firewall_rule_prevents_confirmation(self):
        baseline = {'active': True, 'rules': [], 'config': {}}
        self.w.ufw_snapshot = Mock(return_value=baseline)
        with self.assertRaises(ValueError):
            self.w.firewall_check({'baseline': baseline, 'ports': ['2224'], 'tag': 'owned'}, complete=True)

    def test_public_key_recovery_targets_keys_not_config(self):
        self.assertEqual(self.w.target_file({'kind': 'keys'}), self.w.KEYS)
        self.assertEqual(self.w.target_file({}), self.w.CONFIG)


if __name__ == '__main__':
    unittest.main()
