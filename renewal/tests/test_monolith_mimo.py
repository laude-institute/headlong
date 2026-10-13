"""Shell-contract regressions from the October 12 MiMo incident. Synthetic data only."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2] / 'runtime/headlong'


class CompactToolMarkupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = (ROOT / 'bin/shellm').read_text()
        functions = source[source.index('normalize_toolcall_markup() {'):source.index('\n# System prompt\n')]
        self.parser = self.root / 'parser.sh'
        self.parser.write_text(functions + '\nresponse=$(cat)\nextract_code "$response"\n')
        self.env = {'PATH': os.environ['PATH'], 'HOME': str(self.root), 'TMPDIR': str(self.root)}

    def extract(self, response):
        return subprocess.run(['bash', str(self.parser)], input=response, text=True,
                              capture_output=True, check=True, env=self.env).stdout

    def run_fixture(self, response):
        return subprocess.run(['bash', '-c', self.extract(response)], text=True,
                              capture_output=True, env=self.env, cwd=self.root)

    def wrap(self, code):
        return '<tool_call><function=bash><parameter=command>' + code + '</parameter></function></tool_call>'

    def test_compact_single_line_command(self):
        result = self.run_fixture(self.wrap('printf "%s\\n" ready'))
        self.assertEqual((result.returncode, result.stdout), (0, 'ready\n'))
        self.assertIn('lifted your code', result.stderr)

    def test_incident_shape_with_multiline_body_and_final(self):
        result = self.run_fixture(self.wrap('cd . || exit 1\nprintf "%s\\n" ready\nFINAL="done"'))
        self.assertEqual((result.returncode, result.stdout), (0, 'ready\n'))

    def test_shell_data_is_not_xml_unescaped_or_rewritten(self):
        body = 'cat <<\'DATA\'\n</parameter>\n<value>literal &amp; $HOME</value>\nDATA'
        result = self.run_fixture(self.wrap(body))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '</parameter>\n<value>literal &amp; $HOME</value>\n')

    def test_fenced_code_wins_over_markup(self):
        result = self.run_fixture('Mention <tool_call><function=bash>\n```bash\nprintf ready\n```')
        self.assertEqual((result.returncode, result.stdout), (0, 'ready'))
        self.assertNotIn('lifted your code', result.stderr)

    def test_incomplete_unknown_multiple_and_trailing_content_never_execute(self):
        command = 'touch marker'
        valid = self.wrap(command)
        cases = [valid.removesuffix('</tool_call>'), valid.replace('function=bash', 'function=python'),
                 valid.replace('parameter=command', 'parameter=path'), valid + '\n' + valid,
                 valid + '\ntouch outside', 'prose\n' + valid]
        for response in cases:
            with self.subTest(response=response):
                result = self.run_fixture(response)
                self.assertEqual(result.returncode, 2, result)
                self.assertFalse((self.root/'marker').exists())
                self.assertFalse((self.root/'outside').exists())

    def test_invalid_shell_rejects_whole_recovered_body(self):
        result = self.run_fixture(self.wrap('touch marker\nif'))
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root/'marker').exists())
        self.assertIn('NONE of this script ran', result.stderr)

    def test_existing_fence_and_heredoc_regressions(self):
        for script in ('test_extract_code_notice.sh', 'test_extract_code_heredocs.sh'):
            with self.subTest(script=script):
                result = subprocess.run(['bash', str(ROOT/'tests'/script)], text=True,
                                        capture_output=True, env=self.env, cwd=self.root, timeout=45)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
