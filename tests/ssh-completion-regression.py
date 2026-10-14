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

    def test_one_click_enables_ufw_and_closes_22(self):
        self.w.ufw_snapshot = Mock(return_value={'active': False, 'rules': [], 'config': {}})
        fw = self.w.firewall_plan(['22'], ['64400'], True, 'a' * 32)
        self.assertEqual((fw['ports'], fw['deny'], fw['activate']), (['64400'], ['22'], True))
        self.assertEqual(self.w.firewall_owned(fw)[0], ['deny', '22/tcp', 'comment', fw['tag']])

    def test_one_click_keeps_existing_deny_and_active_state(self):
        self.w.ufw_snapshot = Mock(return_value={'active': True, 'rules': [['deny', '22/tcp'], ['allow', '64400/tcp']], 'config': {}})
        fw = self.w.firewall_plan(['64400'], ['64400'], True, 'a' * 32)
        self.assertEqual((fw['ports'], fw['deny'], fw['activate']), ([], [], False))

    def test_one_click_never_denies_the_new_port_22(self):
        self.w.ufw_snapshot = Mock(return_value={'active': False, 'rules': [], 'config': {}})
        self.assertEqual(self.w.firewall_plan(['22'], ['22'], True, 'a' * 32)['deny'], [])

    def test_apply_enables_ufw_after_rules(self):
        tag = 'daimon-ssh-' + 'a' * 32
        baseline = {'active': False, 'rules': [], 'config': {'/etc/ufw/ufw.conf': 'off'}}
        allow = ['allow', '64400/tcp', 'comment', tag]
        deny = ['deny', '22/tcp', 'comment', tag]
        enabled = {'active': True, 'rules': [deny, allow], 'config': {'/etc/ufw/ufw.conf': 'on'}}
        self.w.ufw_snapshot = Mock(side_effect=[baseline, dict(baseline, rules=[deny]), dict(baseline, rules=[deny, allow]), enabled])
        self.w.command = Mock()
        fw = {'baseline': baseline, 'ports': ['64400'], 'deny': ['22'], 'tag': tag, 'enable': True, 'activate': True}
        self.w.firewall_apply(fw)
        self.assertEqual(self.w.command.call_args_list[-1][0], ('/usr/sbin/ufw', '--force', 'enable'))
        self.assertEqual(self.w.command.call_args_list[0][0], ('/usr/sbin/ufw', *deny))

    def test_restore_disables_ufw_it_enabled(self):
        tag = 'daimon-ssh-' + 'a' * 32
        baseline = {'active': False, 'rules': [['allow', '80/tcp']], 'config': {'/etc/ufw/ufw.conf': 'off'}}
        allow = ['allow', '64400/tcp', 'comment', tag]
        enabled = {'active': True, 'rules': [allow] + baseline['rules'], 'config': {'/etc/ufw/ufw.conf': 'on'}}
        self.w.ufw_snapshot = Mock(side_effect=[enabled, dict(enabled, rules=baseline['rules']), baseline])
        self.w.command = Mock()
        self.w.firewall_restore({'baseline': baseline, 'ports': ['64400'], 'deny': [], 'tag': tag, 'activate': True})
        self.assertEqual(self.w.command.call_args_list[-1][0][:3], ('/usr/sbin/ufw', '--force', 'disable'))

    def test_existing_allow_22_is_swapped_for_deny_and_restored(self):
        tag = 'daimon-ssh-' + 'a' * 32
        baseline = {'active': True, 'rules': [['allow', '80/tcp'], ['allow', '22/tcp'], ['allow', '443/tcp']], 'config': {}}
        self.w.ufw_snapshot = Mock(return_value=baseline)
        fw = self.w.firewall_plan(['22'], ['64400'], True, 'a' * 32)
        self.assertEqual(fw['removed'], [[['allow', '22/tcp'], 1]])
        deny = ['deny', '22/tcp', 'comment', tag]
        allow = ['allow', '64400/tcp', 'comment', tag]
        applied = dict(baseline, rules=[allow, deny, ['allow', '80/tcp'], ['allow', '443/tcp']])
        without = dict(baseline, rules=[['allow', '80/tcp'], ['allow', '443/tcp']])
        self.w.ufw_snapshot = Mock(side_effect=[applied, dict(applied, rules=[allow] + without['rules']), without, baseline])
        self.w.command = Mock()
        self.w.firewall_restore(fw)
        self.assertEqual(self.w.command.call_args_list[-1][0], ('/usr/sbin/ufw', 'insert', '2', 'allow', '22/tcp'))

    def test_one_click_opens_requested_ports_as_owned_rules(self):
        self.w.ufw_snapshot = Mock(return_value={'active': False, 'rules': [['allow', '2096/tcp']], 'config': {}})
        fw = self.w.firewall_plan(['22'], ['64400'], True, 'a' * 32, ['2096/tcp', '20000/tcp', '53245/udp', '20000/tcp'])
        self.assertEqual(fw['open'], ['20000/tcp', '53245/udp'])
        self.assertIn(['allow', '53245/udp', 'comment', fw['tag']], self.w.firewall_owned(fw))
        for bad in ('0/tcp', '70000/tcp', '80', '80/icmp', '80/tcp;id'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                self.w.firewall_plan(['22'], ['64400'], True, 'a' * 32, [bad])

    def test_restore_fails_if_ufw_stays_enabled(self):
        tag = 'daimon-ssh-' + 'a' * 32
        baseline = {'active': False, 'rules': [], 'config': {}}
        self.w.ufw_snapshot = Mock(return_value=dict(baseline, active=True))
        self.w.command = Mock()
        with self.assertRaises(ValueError):
            self.w.firewall_restore({'baseline': baseline, 'ports': [], 'deny': [], 'tag': tag, 'activate': True})

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
