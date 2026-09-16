#!/usr/bin/env python3
"""Download the fixed test engine used by the addon CI matrix."""
from pathlib import Path
import platform
import shutil
import urllib.request
import zipfile

root = Path(__file__).resolve().parents[1] / 'build/godot'
root.mkdir(parents=True, exist_ok=True)
system = platform.system()
asset = {'Darwin': 'macos.universal', 'Linux': 'linux.x86_64', 'Windows': 'win64.exe'}[system]
name = 'Godot_v4.6.3-stable_' + asset + '.zip'
archive = root / name
urllib.request.urlretrieve('https://github.com/godotengine/godot/releases/download/4.6.3-stable/' + name, archive)
with zipfile.ZipFile(archive) as z:
    z.extractall(root)
source = root / ('Godot.app/Contents/MacOS/Godot' if system == 'Darwin' else name[:-4])
target = root / ('Godot.exe' if system == 'Windows' else 'Godot')
if source != target:
    shutil.copy2(source, target)
target.chmod(0o755)
