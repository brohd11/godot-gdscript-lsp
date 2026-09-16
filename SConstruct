import os
from pathlib import Path

local_core = Path('.core-path')
core = Dir(ARGUMENTS.pop('core_dir', local_core.read_text().strip() if local_core.exists() else 'core')).abspath
deps = os.path.join(core, '.deps')
godot_cpp = Dir(ARGUMENTS.pop('godot_cpp', 'godot-cpp')).abspath
ARGUMENTS.setdefault('build_profile', 'build_profile.json')
ARGUMENTS.setdefault('macos_deployment_target', '14.0')
env = SConscript(os.path.join(godot_cpp, 'SConstruct'), {'api_version': '4.6'})
suffix = env['suffix']
if env['platform'] == 'macos':
    suffix = suffix.replace('.universal', '').replace('.arm64', '').replace('.x86_64', '')
    suffix += '.framework/libgdscript_lsp' + suffix
    env['SHLIBSUFFIX'] = ''

env.Append(CPPPATH=['src', deps + '/tree-sitter/lib/include', deps + '/tree-sitter/lib/src',
                   deps + '/tree-sitter-gdscript/src', deps + '/json/include', core + '/src'],
           CXXFLAGS=['/std:c++20'] if env.get('is_msvc', False) else ['-std=c++20'], CPPDEFINES=['_DEFAULT_SOURCE'])
if env.get('is_msvc', False):
    env.Append(CFLAGS=['/std:c11'])
else:
    env.Append(LINKFLAGS=['-pthread'])
sources = list(Path(core, 'src/core').glob('*.cpp')) + list(Path('src/gdextension').glob('*.cpp'))
sources += [Path(deps, 'tree-sitter/lib/src/lib.c'), Path(deps, 'tree-sitter-gdscript/src/parser.c'),
            Path(deps, 'tree-sitter-gdscript/src/scanner.c')]
objects = []
for index, source in enumerate(sources):
    # Keep build outputs out of pinned source checkouts.
    objects += env.SharedObject('build/obj/%s/%s_%s' % (env.get('suffix', 'local'), index, source.stem), str(source))
library = env.SharedLibrary('gdscript_lsp/bin/libgdscript_lsp' + suffix + env['SHLIBSUFFIX'], source=objects)
Default(library)
