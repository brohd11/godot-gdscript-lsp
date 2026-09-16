# Migration validation

Local engine: Godot 4.6.3 on macOS. Both debug and release libraries are built
as Intel/Apple Silicon universal binaries with a macOS 14 deployment target.

Coverage includes full/sparse/bracket comparisons against the current
source-built tree-sitter-gd, semantic completion/type/diagnostic smoke cases,
pre-ready edits, failed indexing, Unicode, malformed text, shared managers,
retained bracket maps, AddonLib integration, and an isolated native-absent
AddonLib project. Standalone tests cover incremental snapshots, deferred
recovery, completion, diagnostics, LSP transport and engine synchronization.

A 1,001-line edit + sparse + brackets comparison (100 measured iterations,
20 warmups) measured old p50/p95 3,126/4,214 us and new 3,416/4,025 us.
An additional run measured old 2,983/3,471 us and new 3,274/3,806 us.
This is one local workload, not a cross-platform latency guarantee.

The release workflow builds and tests Windows/Linux and packages all platforms.
Those runners have not been executed locally. A local development ZIP is
explicitly labeled partial; release packaging rejects missing platform libraries,
non-universal macOS libraries, or an uncommitted core checkout.

The full development editor project reports an unresolved EditorConsole UID
(`uid://cnuejrhrodgbx`) and a resulting `UOs` parse error, plus resource/RID
retention warnings at shutdown. This prevents claiming a clean full-project
startup. The isolated native and native-absent parser tests pass, as does
Code Completions/SyntaxPlus initialization in both configurations. The editor
probe confirms that completion acquires the shared native service. Both editor
configurations report the same plugin resource/RID retention warnings on exit.
Windows/Linux execution and minimum-macOS runtime testing remain CI or
platform-machine validation tasks.
