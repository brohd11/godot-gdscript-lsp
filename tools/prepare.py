#!/usr/bin/env python3
"""Fetch pinned parser dependencies and stage the core's native API metadata."""
from pathlib import Path
import argparse
import shutil
import subprocess

repo = Path(__file__).resolve().parents[1]
local_core = repo / '.core-path'
parser = argparse.ArgumentParser()
parser.add_argument('--core', type=Path, default=Path(local_core.read_text().strip()) if local_core.exists() else repo / 'core')
args = parser.parse_args()
core = args.core.resolve()
repo = Path(__file__).resolve().parents[1]
subprocess.run(['sh', str(core / 'tools/fetch_dependencies.sh'), str(core / '.deps')], check=True)
data = repo / 'gdscript_lsp/data'
data.mkdir(parents=True, exist_ok=True)
shutil.copy2(core / 'data/godot-4.6-extension-api.json', data)
