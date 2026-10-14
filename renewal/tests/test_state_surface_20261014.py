import datetime as dt
import json
import sys
import tempfile
import io
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import custos_state_surface as surface

class SurfaceTests(unittest.TestCase):
    def test_timeout_never_displays_stale_cached_goals(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache=Path(tmp)/'cache.json';cache.write_text(json.dumps({'ts':0,'data':{'goals':[{'goal_id':'old'}]}}))
            with patch.object(surface,'CACHE',str(cache)), patch.object(surface,'run',return_value=(124,'','timeout')):
                result,source=surface.collect_goals(use_cache=False)
        self.assertIsInstance(result,str);self.assertIn('unavailable',result)
        self.assertEqual(source,'unavailable');self.assertNotIn('old',result)

    def test_fresh_context_includes_own_structured_waits(self):
        data={'goals':[],'waiting':[{'goal_id':'own','signal_target':'Kim','reason':'await lane'}]}
        with tempfile.TemporaryDirectory() as tmp, patch.object(surface,'CACHE',str(Path(tmp)/'cache.json')), patch.object(surface,'run',return_value=(0,json.dumps(data),'')) as command:
            result,source=surface.collect_goals()
        command.assert_called_once_with(['custos-memory','context','--json'],timeout=90)
        self.assertEqual(result,data);self.assertEqual(source,'fresh')

    def test_requested_unavailable_goals_return_failure(self):
        with patch.object(sys,'argv',['surface','--goals']), patch.object(surface,'collect_goals',return_value=('unavailable','unavailable')), patch.object(surface,'collect_todos',return_value=([],None)), patch.object(surface,'collect_pr',return_value=({},None)), patch('sys.stdout',io.StringIO()):
            self.assertEqual(surface.main(),2)

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
