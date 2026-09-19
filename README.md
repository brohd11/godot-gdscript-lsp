# Godot GDScript language service

Optional native parsing and completion support for Godot 4.6. One addon package
contains Windows/Linux x86_64 and universal macOS libraries (macOS 14+).
Install the release ZIP over the project root. It creates
`addons/addon_lib/gdscript_lsp`. There is no editor plugin to enable and no
AddonLib dependency. AddonLib, SyntaxPlus and Code Completions discover it when
installed; their GDScript paths remain available without it.

## Ownership

`service.gd` extends `Node` directly. `get_instance()` finds or creates
`EditorNode/EditorSingletons/GDScriptLSPService` in the editor, or
`/root/GDScriptLSPService` at runtime, on the main thread.
`code_edit_manager.gd` exposes `GDScriptLSPCodeEditManager`: attach a CodeEdit and
script path, then call `parse()`, `sparse_parse()`, or inspect `parser.get_brackets()`.
Managers share one document per attached source. Detach managers when finished.
Use `is_attached()` to distinguish a live attachment (including an empty file)
from an unavailable backend or a detached/discarded buffer. It does not synchronize
the buffer or wait for semantic indexing. It becomes false when the CodeEdit
leaves the tree or the service is freed; call `attach()` again to reattach.
Full dictionaries may be modified; sparse and live bracket dictionaries are
shared, read-only views. `get_parse_revision()` is monotonic across attachments.

Read-only `document_for_path()` checks saved source on access and repairs missed file
notifications without registering an editor buffer. Changed syntax is available immediately;
semantic refresh runs asynchronously. `GDScriptLSPDocument.get_source_code()` returns the
exact text associated with its structural revision, including unsaved editor text when open.
Filesystem scans refresh additions, modifications, deletions, and UID mappings. Unchanged
reads retain their revision and schedule no indexing work. On access, high-resolution
modification time and size gate source reads; explicit notifications force a recheck.
`get_source_hash()` caches the hash per structural snapshot. File events are coalesced
for 100 ms; pathless events scan metadata on the indexing worker, and a batch rebuilds
the registry once. `get_refresh_stats()` reports read-only source reads, background
metadata scans, and disk refresh batches for performance checks.

Structural reads work before semantic indexing finishes. Native semantic reads
are nonblocking and fall through while a revision is pending. Existing semantic
API columns are UTF-16; use `GDScriptLSPService.utf16_column()` for CodeEdit columns.
Compatibility structural projections retain tree-sitter-gd's byte-column fields
(including lambdas); brackets use character columns. Lambda entries expose
`line_index`, `column_index`, `end_line`, and `end_column`, with nested closures
under `lambdas`. These positions are zero-based, columns count UTF-8 bytes, and
end positions are exclusive. These field names, nesting, and units are a
compatibility contract. AddonLib owns its parser
objects, type paths, and conversion of those projections into its public API.

The native `GDScriptLanguageService` also supports direct use without an editor:
`update_document(uri, text, revision)` synchronously makes syntax available through
`document(uri).parse_script(uri)` and `document(uri).sparse_parse()`, without
requiring `open_workspace()` or either readiness check. Revisions must increase
for each source.

`open_workspace()` starts asynchronous indexing. Returning `OK` means the work
was started, not that indexing finished or succeeded. `is_ready()` becomes true
when successful opening is delivered on the main loop via `workspace_ready`;
failure emits `workspace_error` and leaves it false. Connect both signals before
opening, and allow the main loop to run:

```gdscript
var service = ClassDB.instantiate(&"GDScriptLanguageService")
service.workspace_ready.connect(func(): print("Workspace opened"))
service.workspace_error.connect(func(message: String): push_error(message))
service.open_workspace("res://")
```

`is_document_ready(uri)` checks whether semantic queries can use the current
document revision. It can be false during pending updates or lock contention,
even after `workspace_ready`. Structural reads deliberately do not require it;
for semantic reads, retry on a later frame or after `index_updated`.

## Build

Initialize the pinned `core` and `godot-cpp` submodules:

```sh
git submodule update --init --recursive
python3 tools/prepare.py
scons platform=macos arch=universal target=template_debug
scons platform=macos arch=universal target=template_release
python3 tests/run.py --godot /path/to/Godot
```

For Linux/Windows use `platform=linux`/`platform=windows`, `arch=x86_64`.
`build_profile.json` limits bindings to the native classes used by this extension.
Use `core_dir=/path/to/gdscript-lsp` and `tools/prepare.py --core ...` to develop
against a sibling checkout. The core owns the grammar/runtime pins and patches.

```sh
python3 package.py --version 0.1.0
```

Release packaging requires all six debug/release library entries and a clean
core checkout. It writes one ZIP and a checksum; `build.json` records the pinned
core revision. `--development --core /path/to/core` makes an explicitly local-only
partial package for testing. CI builds all platforms before publishing a tag.

## Migration checkout

This initial migration changes the core and consumer together. Commit and push
the shared-core changes first, then update this repository's `core` submodule
to that commit before committing/releasing the consumer. The ignored `.core-path`
file selects the sibling working tree during this migration; delete it once the
submodule is updated to test the release checkout. For example, after committing
the shared repository's core changes:

```sh
git -C core fetch /path/to/gdscript-lsp HEAD
git -C core checkout --detach FETCH_HEAD
git add core
```

The submodule starts clean at the pre-migration commit; the local override makes
the uncommitted migration buildable without creating commits for you. AddonLib, SyntaxPlus,
and Code Completions changes are separate repository changes and should ship
before removing tree-sitter-gd from an existing installation.

`tests/run.py --legacy-addon /path/to/tree_sitter_gd` additionally compares the
old full/sparse/bracket projections in an isolated project. The old extension
is only a test oracle and is never included in the package.

`tests/run_addons.py --godot /path/to/Godot --project /path/to/integration-project`
checks AddonLib parsing and Code Completions/SyntaxPlus editor initialization,
both with and without the native addon.
