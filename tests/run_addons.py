#!/usr/bin/env python3
"""Validate consumer parsing with and without the native addon in a clean project."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--godot', default='godot')
parser.add_argument('--project', type=Path, required=True, help='Integration project with AddonLib and consumer plugins')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
(repo / 'build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='addon-integration-', dir=repo / 'build') as temporary:
    project = Path(temporary)
    shutil.copytree(args.project / 'addons', project / 'addons', ignore=shutil.ignore_patterns(
        '.git', 'bin', 'gdscript_lsp', 'tree_sitter_gd', '*.gdextension', '.DS_Store'))
    (project / 'project.godot').write_text('[application]\nconfig/name="Native-absent integration"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    shutil.copy2(repo / 'tests/addon_integration.gd', project / 'test.gd')
    shutil.copy2(repo / 'tests/scratch_reader.gd', project / 'scratch_reader.gd')
    def run(extra):
        result = subprocess.run([args.godot, '--headless', '--path', str(project), '--log-file', str(project / 'godot.log'), *extra],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        for line in result.stdout.splitlines():
            if '\x1b' not in line:
                print(line, flush=True)
        if result.returncode or 'SCRIPT ERROR' in result.stdout or 'FAIL:' in result.stdout:
            raise SystemExit(result.returncode or 1)
        return result.stdout

    base_config = (project / 'project.godot').read_text()
    run(['--editor', '--import', '--quit'])
    run(['--script', 'res://test.gd'])
    probe = project / 'addons/migration_probe'
    probe.mkdir()
    shutil.copy2(repo / 'tests/editor_probe.gd', probe / 'plugin.gd')
    (probe / 'plugin.cfg').write_text('[plugin]\nname="Migration probe"\ndescription="Integration check"\nauthor=""\nversion="1"\nscript="plugin.gd"\n')
    editor_config = base_config + '\n[editor_plugins]\nenabled=PackedStringArray("res://addons/code_completions/plugin.cfg", "res://addons/migration_probe/plugin.cfg")\n'
    (project / 'project.godot').write_text(editor_config)
    assert 'PASS: editor consumer initialization' in run(['--editor', '--quit-after', '600'])
    (project / 'project.godot').write_text(base_config)
    shutil.copytree(repo / 'gdscript_lsp', project / 'addons/addon_lib/gdscript_lsp')
    run(['--editor', '--quit-after', '60'])
    run(['--script', 'res://test.gd'])
    run(['--script', 'res://scratch_reader.gd'])
    (project / 'project.godot').write_text(editor_config)
    assert 'PASS: editor consumer initialization' in run(['--editor', '--quit-after', '600'])
