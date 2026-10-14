import datetime as dt
import json
import sys
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import custos_state_surface as surface

class SurfaceTests(unittest.TestCase):
    def test_json_guard_states_and_exact_iso_deadline(self):
        for state, ok, deadline in [('open',True,None),('unresolved',False,None),('cooldown',False,'2026-10-15T03:00:00+00:00')]:
            with patch.object(surface.subprocess,'run',return_value=Mock(returncode=0 if ok else 1, stdout=json.dumps({'ok':ok,'state':state,'resume_at':deadline,'channel':'signal'}))):
                result=surface.guard_check('signal-room',2,False)
            self.assertEqual(result['open'],ok);self.assertEqual(result['state'],state)
            self.assertEqual(result['reopen'],dt.datetime.fromisoformat(deadline) if deadline else None)
    def test_event_wait_is_not_rendered_as_missing_fire_time(self):
        text=surface.text_output(surface.NOW,{'waiting':[{'goal_id':'one','summary':'wait','receipt':'action:one','reason':'receipt change'}]},'fresh',[],None,{'health':{}},None,[],[])
        self.assertIn('event wait; no clock deadline',text);self.assertNotIn('eligible ?',text)
    def test_missing_receipt_does_not_crash(self):
        self.assertIn('phase=queued','\n'.join(surface.fmt_receipt({'phase':'queued','receipt':None})))
