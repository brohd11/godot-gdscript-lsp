#!/usr/bin/env python3
"""Stage a clean project with no AddonLib dependency, then run native tests."""
import argparse
import os
from pathlib import Path
import shutil
import shlex
import signal
import subprocess
import tempfile
import zipfile

repo = Path(__file__).resolve().parents[1]
local_core = repo / '.core-path'
parser = argparse.ArgumentParser()
parser.add_argument('--godot', default='godot')
parser.add_argument('--legacy-addon', type=Path)
parser.add_argument('--archive', type=Path, help='Test an extracted package instead of the source addon')
parser.add_argument('--core', type=Path, default=Path(local_core.read_text().strip()) if local_core.exists() else repo / 'core')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
(repo / 'build').mkdir(exist_ok=True)
staging = tempfile.TemporaryDirectory(prefix='test-project-', dir=repo / 'build')
project = Path(staging.name)
addon = project / 'addons/addon_lib/gdscript_lsp'
if args.archive:
    with zipfile.ZipFile(args.archive) as archive:
        archive.extractall(project)
else:
    shutil.copytree(repo / 'gdscript_lsp', addon, dirs_exist_ok=True)
shutil.copytree(repo / 'tests', project / 'tests', dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('addon_integration.gd', 'highlighter_integration.gd'))
fixtures = args.core.resolve() / 'tests/fixtures/basic'
if fixtures.is_dir():
    shutil.copytree(fixtures, project / 'tests/fixtures/basic', dirs_exist_ok=True)
    # Path.as_uri supplies the third slash before Windows drive letters and
    # percent-encodes spaces, Unicode and literal percent signs on all hosts.
    (project / 'tests/consumer_uri.txt').write_text(
        (project / 'tests/fixtures/basic/consumer.gd').resolve().as_uri(), encoding='utf-8')
if args.legacy_addon:
    shutil.copytree(args.legacy_addon, project / 'addons/addon_lib/tree_sitter_gd', dirs_exist_ok=True)
(project / 'project.godot').write_text('[application]\nconfig/name="Language service tests"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
(project / 'fixture.gd').write_text('extends RefCounted\nvar saved: int = 1\n')
env = os.environ.copy()


def run(command):
    print('Running:', shlex.join(command), flush=True)
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    print(result.stdout, flush=True)
    if result.returncode:
        reason = (signal.Signals(-result.returncode).name if result.returncode < 0
                  else 'exit code %s' % result.returncode)
        print('Godot failed:', reason, flush=True)
    if result.returncode or 'SCRIPT ERROR' in result.stdout or 'FAIL:' in result.stdout:
        raise SystemExit(1)


for command in [
    [args.godot, '--headless', '--log-file', str(project / 'godot.log'), '--path', str(project), '--editor', '--quit-after', '60'],
    [args.godot, '--headless', '--log-file', str(project / 'godot.log'), '--path', str(project), '--script', 'res://tests/native.gd'],
    [args.godot, '--headless', '--log-file', str(project / 'godot.log'), '--path', str(project), '--script', 'res://tests/readonly.gd'],
    *([[args.godot, '--headless', '--log-file', str(project / 'godot.log'), '--path', str(project), '--script', 'res://tests/semantic.gd']] if fixtures.is_dir() else []),
    [args.godot, '--headless', '--log-file', str(project / 'godot.log'), '--path', str(project), '--script', 'res://tests/benchmark.gd'],
]:
    run(command)

# Stage only wrapper scripts so this check cannot accidentally load a native backend.
with tempfile.TemporaryDirectory(prefix='test-no-extension-', dir=repo / 'build') as temporary:
    absent_project = Path(temporary)
    absent_addon = absent_project / 'addons/addon_lib/gdscript_lsp'
    absent_addon.mkdir(parents=True)
    for script in ('service.gd', 'code_edit_manager.gd'):
        shutil.copy2(addon / script, absent_addon / script)
    shutil.copy2(repo / 'tests/manager_unavailable.gd', absent_project / 'test.gd')
    shutil.copy2(project / 'project.godot', absent_project / 'project.godot')
    run([args.godot, '--headless', '--log-file', str(absent_project / 'godot.log'),
         '--path', str(absent_project), '--script', 'res://test.gd'])
