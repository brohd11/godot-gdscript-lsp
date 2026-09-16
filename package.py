#!/usr/bin/env python3
"""Create the single, project-root-relative addon archive. Never publish partial builds."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent
REQUIRED = [
    'libgdscript_lsp.%s.template_%s.x86_64.%s' % (platform, mode, extension)
    for platform, extension in [('linux', 'so'), ('windows', 'dll')]
    for mode in ['debug', 'release']
] + [
    'libgdscript_lsp.macos.template_%s.framework/libgdscript_lsp.macos.template_%s' % (mode, mode)
    for mode in ['debug', 'release']
]

def package(version, core, development=False):
    addon = ROOT / 'gdscript_lsp'
    missing = [name for name in REQUIRED if not (addon / 'bin' / name).is_file() or (addon / 'bin' / name).stat().st_size == 0]
    if missing and not development:
        raise RuntimeError('Missing release libraries: ' + ', '.join(missing))
    if not development:
        for name in REQUIRED[-2:]:
            binary = (addon / 'bin' / name).read_bytes()
            magic, count = struct.unpack_from('>II', binary)
            stride = 32 if magic == 0xcafebabf else 20
            if magic not in (0xcafebabe, 0xcafebabf) or len(binary) < 8 + count * stride:
                raise RuntimeError('macOS release libraries must be universal: ' + name)
            architectures = {struct.unpack_from('>I', binary, 8 + index * stride)[0] for index in range(count)}
            if not {0x01000007, 0x0100000c}.issubset(architectures):
                raise RuntimeError('Missing Intel or Apple Silicon architecture: ' + name)
    metadata = core / 'data/godot-4.6-extension-api.json'
    if not metadata.is_file():
        raise RuntimeError('Run tools/prepare.py against the migrated core checkout first')
    commit = subprocess.check_output(['git', '-C', str(core), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = bool(subprocess.check_output(['git', '-C', str(core), 'status', '--porcelain'], text=True).strip())
    if dirty and not development:
        raise RuntimeError('Commit the core changes and update the core submodule before packaging a release')
    output = ROOT / 'dist'
    output.mkdir(exist_ok=True)
    suffix = '-dev' if development else '-v' + version
    archive = output / ('gdscript-lsp' + suffix + '.zip')
    with tempfile.TemporaryDirectory(prefix='gdscript-lsp-package-') as temporary:
        stage = Path(temporary)
        target = stage / 'addons/addon_lib/gdscript_lsp'
        shutil.copytree(addon, target, ignore=shutil.ignore_patterns('*.os', '*.lib', '*.exp', '.DS_Store'))
        (target / 'data').mkdir(exist_ok=True)
        shutil.copy2(metadata, target / 'data' / metadata.name)
        for name in ['LICENSE', 'README.md', 'THIRD_PARTY_NOTICES.md']:
            shutil.copy2(ROOT / name, target / name)
        (target / 'version.cfg').write_text('[plugin]\nversion="%s"\n' % version)
        (target / 'build.json').write_text(json.dumps({'version': version, 'core_revision': commit,
            'core_dirty': dirty, 'development': development}, indent=2) + '\n')
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            for path in sorted(target.rglob('*')):
                if path.is_file():
                    z.write(path, path.relative_to(stage))
    archive.with_suffix('.zip.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
    print(archive)
    return archive

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    parser.add_argument('--core', type=Path, default=ROOT / 'core')
    parser.add_argument('--development', action='store_true', help='Produce a clearly labeled local-only partial package')
    args = parser.parse_args()
    package(args.version.removeprefix('v'), args.core.resolve(), args.development)
