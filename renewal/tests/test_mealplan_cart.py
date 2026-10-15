from contextlib import redirect_stdout
import importlib.machinery, importlib.util, io, json
from pathlib import Path
import sys, unittest
from unittest.mock import patch
loader=importlib.machinery.SourceFileLoader('mealplan_cart_cli',str(Path(__file__).resolve().parents[1]/'bin'/'mealplan'))
spec=importlib.util.spec_from_loader(loader.name,loader)
cli=importlib.util.module_from_spec(spec);loader.exec_module(cli)

class CartViewTests(unittest.TestCase):
    def invoke(self,args,response):
        out=io.StringIO()
        with patch.object(cli,'call',return_value=response) as call, patch.object(sys,'argv',['mealplan']+args), redirect_stdout(out): cli.main()
        return json.loads(out.getvalue()),call
    def test_cart_show_uses_retailer_without_stale_active_cycle(self):
        carts=[{'program':'GROCERY','items':[{'asin':'MANUAL','quantity':2}]}]
        for suffix in ([],['--week','2026-W43']):
            result,call=self.invoke(['cart','show']+suffix,{'carts':carts})
            call.assert_called_once_with('GET','/shopper/cart')
            self.assertEqual(result['carts'],carts);self.assertEqual(result['view'],'retailer_cart')
            self.assertNotIn('operations',result);self.assertFalse(result['cart_updated'])
    def test_preview_cannot_report_cart_updated(self):
        result,call=self.invoke(['list','preview','--week','2026-W43'],{'operations':[{'asin':'MISSING','quantity':4}],'cart_updated':True})
        call.assert_called_once_with('GET','/flow/2026-W43/preview')
        self.assertEqual(result['cycle_id'],'2026-W43');self.assertTrue(result['read_only']);self.assertFalse(result['cart_updated'])
    def test_missing_or_failed_retailer_read_is_not_empty_cart_success(self):
        for response in ({'error':'signed out'},{},None,{'carts':None}):
            with patch.object(cli,'call',return_value=response),self.assertRaises(ValueError):cli.retailer_cart()
    def test_empty_valid_cart_is_distinct_from_failure(self):
        result,call=self.invoke(['cart','show'],{'carts':[]});self.assertEqual(result['carts'],[])
