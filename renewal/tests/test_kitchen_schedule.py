"""Requested kitchen contacts remain narrow, cancellable and deduplicable."""
import json, pathlib, sqlite3, sys, unittest
from datetime import datetime
from zoneinfo import ZoneInfo
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
import custos_kitchen as k

def ts(text): return datetime.fromisoformat(text).replace(tzinfo=ZoneInfo('America/Denver')).timestamp()

class ScheduleTests(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:');self.db.row_factory=sqlite3.Row
        self.db.execute('CREATE TABLE inbox(id TEXT,payload TEXT)');self.addCleanup(self.db.close)
        self.policy={'people':{'hal':{'authority':'operator','label':'Hal'},'stranger':{'authority':'external','label':'Other'}},
            'kitchen_checkins':{'enabled':True,'target':'group:home','authorized_at':ts('2026-10-10T20:00'),
             'wednesday':{'at':'15:00'},'friday':{'at':'12:00'},'bootstrap_id':'kitchen-pantry-bootstrap-20261010'}}

    def allowed(self,ident='kitchen-wednesday:2026-10-14',when='2026-10-14T15:00',target='group:home'):
        return k.scheduled_authorized(self.db,self.policy,target,ident,ts(when))

    def add(self,body,when='2026-10-13T10:00',who='hal'):
        self.db.execute('INSERT INTO inbox VALUES (?,?)',(body,json.dumps({'body':body,'timestamp':ts(when)*1000,'sender_aci':who,'conversation':'group:home'})))

    def test_exact_due_slot_and_destination_only(self):
        self.assertTrue(self.allowed())
        for args in [{'target':'dm:hal'},{'when':'2026-10-14T14:59'},{'when':'2026-10-14T21:01'},
                     {'ident':'kitchen-wednesday:2026-10-15'},{'ident':'kitchen-wednesday:2026-10-14-retry'},
                     {'ident':'kitchen-thursday:2026-10-15'}]: self.assertFalse(self.allowed(**args))

    def test_friday_cannot_send_before_audit_window_ends_at_noon(self):
        self.assertFalse(self.allowed('kitchen-friday:2026-10-16','2026-10-16T11:59'))
        self.assertTrue(self.allowed('kitchen-friday:2026-10-16','2026-10-16T12:00'))

    def test_dst_uses_denver_noon(self):
        self.assertTrue(self.allowed('kitchen-friday:2026-11-06','2026-11-06T12:00'))

    def test_new_opt_out_wins_but_old_retirement_does_not(self):
        self.add('Leave the rest to us','2026-10-02T10:00')
        self.assertTrue(self.allowed())
        self.add('Please stop the kitchen check-ins')
        self.assertFalse(self.allowed())

    def test_external_person_cannot_cancel(self):
        self.add('Stop the check-ins',who='stranger');self.assertTrue(self.allowed())

    def test_skip_only_current_week_and_all_set_closes_transaction(self):
        self.add("We're all set");self.assertTrue(self.allowed())
        self.add('Skip this week');self.assertFalse(self.allowed())
        self.assertTrue(self.allowed('kitchen-wednesday:2026-10-21','2026-10-21T15:00'))

    def test_scheduled_exception_keeps_checkout_guard(self):
        with patch.object(k.time,'time',return_value=ts('2026-10-14T15:00')):
            self.assertIsNone(k.delivery_block(self.db,self.policy,'group:home','Recipe names and links',send_id='kitchen-wednesday:2026-10-14'))
            self.assertIsNotNone(k.delivery_block(self.db,self.policy,'group:home','Last call: place the order',send_id='kitchen-wednesday:2026-10-14'))
            self.assertIsNotNone(k.delivery_block(self.db,self.policy,'group:home','Recipe names and links'))

    def test_bootstrap_is_fixed_id_with_bounded_window(self):
        self.assertTrue(self.allowed('kitchen-pantry-bootstrap-20261010','2026-10-11T10:00'))
        self.assertFalse(self.allowed('kitchen-pantry-bootstrap-20261010-again','2026-10-11T10:00'))
        self.assertFalse(self.allowed('kitchen-pantry-bootstrap-20261010','2026-10-20T10:00'))

    def test_inventory_clues_have_and_depleted(self):
        for text in ['We have onions',"We're out of cumin",'I am low on butter']:
            self.assertEqual(k.fallback(text)['kind'],'inventory')
