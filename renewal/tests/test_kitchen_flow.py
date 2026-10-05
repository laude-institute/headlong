"""Regression replays for kitchen meaning, household stop conditions and intake races."""
import json, os, pathlib, sqlite3, tempfile, unittest, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from unittest.mock import patch
import custos_kitchen as k
import custos_memory as cm
from test_memory import MemoryFixture

DIP='Finnegan and I like to make a Greek yogurt + peanut butter + maple syrup dip to eat with our apple slices.'
def incoming(body, rid='signal:dani'):
    return {'request_id':rid,'authority':'operator','sender':'signal-dani','source_url':rid,'content':'Message:\n'+body}
def plan(): return {'decision':'reply','reply':'Got it.','goal':None,'person':None,'memories':[]}

class MeaningTests(unittest.TestCase):
    def test_exact_dip_never_shops_even_if_model_proposes_it(self):
        p=plan(); p.update(decision='defer',reply="I'll add them.",goal={'outcome':'buy dip ingredients'})
        p['kitchen']={'kind':'request','action':'add','evidence':'make a Greek yogurt'}
        result=cm.apply_quick_ask(incoming(DIP),p)
        self.assertIsNone(result['goal']); self.assertEqual(result['decision'],'no-reply')
    def test_requested_yogurt_is_durable_and_silent(self):
        p=cm.apply_quick_ask(incoming('Please add Greek yogurt to the cart'),plan())
        self.assertEqual(p['decision'],'defer'); self.assertEqual(p['reply'],''); self.assertIn('source-backed add',p['goal']['next_action'])
    def test_remove_and_inventory_are_not_adds(self):
        for words,action in [('Remove peanut butter from the cart','remove'),('I already have yogurt','inventory')]:
            p=cm.apply_quick_ask(incoming(words),plan()); self.assertEqual(p['kitchen']['action'],action)
            self.assertNotIn('source-backed add',p['goal']['next_action'])
    def test_bare_recipe_link_is_not_task(self):
        p=cm.apply_quick_ask(incoming('https://recipes.example/gratin'),plan()); self.assertIsNone(p['goal'])
    def test_implicit_acceptance_uses_source_grounded_semantics(self):
        p=plan(); p['kitchen']={'kind':'request','action':'recipe','evidence':'Yes, add that for Thursday','items':['gratin proposed in conversation'],'date':'2026-10-08'}
        p=cm.apply_quick_ask(incoming('Yes, add that for Thursday'),p)
        self.assertEqual(p['decision'],'defer'); self.assertIn('gratin proposed',p['goal']['next_action'])
    def test_unverified_source_quote_rejected(self):
        with self.assertRaises(ValueError): k.interpret(incoming('Sounds tasty'),{'kind':'request','action':'add','evidence':'add yogurt'})
    def test_context_and_stop_do_not_replace_person_with_food(self):
        p=cm.apply_quick_ask(incoming(DIP),{**plan(),'person':{'notes':'dip details'}}); self.assertIsNone(p['person'])
        self.assertIsNone(cm.apply_quick_ask(incoming("We're all set Custos"),plan())['goal'])
    def test_timed_reminder_keeps_original_mechanism(self):
        self.assertIsNone(k.interpret(incoming('Remind me tomorrow at 6:15 to put rice in the rice cooker')))
    def test_envelope_preserves_typed_kitchen_field(self):
        p=plan();p['kitchen']={'kind':'context','action':'context','evidence':DIP}
        self.assertEqual(cm.validate_plan(json.dumps(p))['kitchen'],p['kitchen'])

class IntakeTests(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:'); self.db.row_factory=sqlite3.Row
        self.db.execute('CREATE TABLE inbox(id TEXT,payload TEXT)')
        self.policy={'people':{'dani':{'label':'Dani','authority':'operator'},'other':{'label':'Other','authority':'external'}}}
    def tearDown(self): self.db.close()
    def add(self,key,body,ts,who='dani'):
        self.db.execute('INSERT INTO inbox VALUES (?,?)',(key,json.dumps({'sender_aci':who,'body':body,'timestamp':ts,'conversation':'group:home'})))
    def test_pending_intake_changes_cursor_before_guest_delivery(self):
        before=k.household_context(self.db,self.policy)['cursor'];self.add('s1','I have yogurt',1000)
        after=k.household_context(self.db,self.policy);self.assertNotEqual(before,after['cursor']);self.assertEqual(after['messages'][0]['body'],'I have yogurt')
        self.add('x','Please buy my groceries',2000,'other');self.assertEqual(k.household_context(self.db,self.policy)['cursor'],after['cursor'])
    def test_all_set_blocks_staged_result_but_new_request_reopens(self):
        self.add('s1','Add yogurt to the cart',1000);self.add('s2',"We're all set Custos",2000)
        self.assertIsNotNone(k.delivery_block(self.db,self.policy,'group:home','Cart ready','s1'))
        self.add('s3','Please add milk to the cart',3000)
        self.assertIsNone(k.delivery_block(self.db,self.policy,'group:home','Milk is in the cart','s3'))
    def test_checkout_nag_blocked_and_requested_reminder_allowed(self):
        self.add('s1','Please remind me about pickup tomorrow',1000)
        self.assertIsNone(k.delivery_block(self.db,self.policy,'group:home','Your requested pickup reminder','s1'))
        self.assertIsNotNone(k.delivery_block(self.db,self.policy,'group:home','Last call before I stop nagging: place the order in your cart'))
    def test_stale_mutation_fails_before_lock_or_write(self):
        with patch.object(k,'family_messages',return_value=('b'*64,[])):
            with self.assertRaisesRegex(ValueError,'new household message'):
                with k.mutation_guard('a'*64,'2026-W40','12345678'): self.fail('stale write admitted')

class NativeKitchenTests(MemoryFixture):
    def test_closure_is_structural_and_settles_existing_kitchen_task(self):
        a=self.store.capture(incoming('Please add yogurt to the cart','signal:one'),'trigger-one',deferred=True)['goal_id']
        self.store.capture(incoming("We're all set Custos",'signal:two'),'trigger-two')
        self.assertFalse(json.loads((self.store.state_dir()/'kitchen-consent.json').read_text())['automatic_followups'])
        self.store.context();r=self.store.find(a)[4]
        self.assertEqual(r['status'],'completed');self.assertIn('no purchase asserted',r['resolution']['evidence'])
    def test_two_tasks_one_cycle_lease_and_new_input_recovery(self):
        a=self.store.capture(incoming('Add yogurt to the cart','signal:one'),'one',deferred=True)['goal_id']
        b=self.store.capture(incoming('Remove milk from the cart','signal:two'),'two',deferred=True)['goal_id']
        with tempfile.TemporaryDirectory() as identity, patch.dict(os.environ,{'IDENTITY_DIR':identity}), patch.object(cm,'Store',return_value=self.store), patch.object(k,'family_messages',return_value=('a'*64,[])):
            with k.mutation_guard('a'*64,'2026-W40',a): pass
            with self.assertRaisesRegex(ValueError,'another native kitchen task'):
                with k.mutation_guard('a'*64,'2026-W40',b): pass
            with patch.object(k,'family_messages',return_value=('b'*64,[])):
                with k.mutation_guard('b'*64,'2026-W40',b): pass

class HostBridgeTests(unittest.TestCase):
    def test_deployed_host_bridge_suppresses_both_queues_after_closure(self):
        import importlib.util
        from unittest.mock import Mock
        import custos_actions as actions
        from test_signal import POLICY, envelope
        path=pathlib.Path(__file__).resolve().parents[1]/'host-kitchen'/'custos_signal.py'
        spec=importlib.util.spec_from_file_location('kitchen_host_signal',path); bridge_module=importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge_module)
        with tempfile.TemporaryDirectory() as temp:
            root=pathlib.Path(temp); policy=root/'policy.json'; policy.write_text(json.dumps(POLICY))
            spool=bridge_module.Spool(root/'spool.sqlite'); channel=actions.Channel(root/'actions.sqlite',policy,root/'spool.sqlite')
            first=bridge_module.classify(envelope(message='Please add yogurt to the cart',timestamp=1000),POLICY); spool.receive(first)
            with spool.db: spool.db.execute("UPDATE inbox SET phase='queued'")
            spool.batch(first['route'],{'trajectory':'test','offset':1,'events':[{'step_id':'result','request_id':first['request_id'],'content':'Yogurt is in the cart'}]})
            channel.handle({'action':'signal-send','request_id':'parallel','target':first['conversation'],'message':'Yogurt is in the cart','reply_to':first['request_id']})
            spool.receive(bridge_module.classify(envelope(message="We're all set Custos",timestamp=2000),POLICY))
            bridge=bridge_module.Bridge(policy,spool,root/'actions.sqlite'); bridge.rpc=Mock()
            with patch.object(bridge_module,'paused',return_value=False),patch.object(bridge_module,'transport',return_value={'trajectory':'test','offset':1,'events':[]}):
                bridge.tick();bridge.proactive()
            self.assertFalse([c for c in bridge.rpc.call.call_args_list if c.args[0]=='send'])
            self.assertEqual(channel.handle({'action':'status','request_id':'parallel'})['phase'],'blocked')
            self.assertEqual(spool.db.execute('SELECT phase FROM outbox').fetchone()[0],'suppressed');spool.db.close()
