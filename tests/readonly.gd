extends SceneTree

const Service = preload("res://addons/addon_lib/gdscript_lsp/service.gd")
const Manager = preload("res://addons/addon_lib/gdscript_lsp/code_edit_manager.gd")
const PATH := "res://fixture.gd"
var failures := 0
var updates := 0

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: " + message)

func _initialize() -> void:
	_run.call_deferred()

func wait_ready(native: Object, minimum_updates := 0) -> void:
	for attempt in range(500):
		if native.is_document_ready(PATH) and updates >= minimum_updates:
			return
		await create_timer(0.01).timeout
	check(false, "workspace becomes ready")

func has_member(document: Object, member: String) -> bool:
	return document != null and document.parse_script(PATH).get("", {}).get("members", {}).has(member)

func _run() -> void:
	# No workspace: the supplied text must work without becoming an open document.
	var unindexed: Object = ClassDB.instantiate(&"GDScriptLanguageService")
	var fallback: Object = unindexed.document_for_path(PATH, "var before: int\n")
	check(has_member(fallback, "before"), "unindexed text fallback is parsed")
	check(unindexed.document(PATH) == null, "fallback does not open a document")
	var revision: int = fallback.get_revision()
	check(unindexed.document_for_path(PATH, "var before: int\n").get_revision() == revision,
		"identical fallback text retains its revision")
	fallback = unindexed.document_for_path(PATH, "var after: String\n")
	check(fallback.get_revision() != revision and has_member(fallback, "after"), "fallback changes invalidate structure")
	check(unindexed.document_for_path("res://missing.gd") == null, "missing snapshot without text declines")
	unindexed = null
	fallback = null

	var wrapper: Node = Service.get_instance()
	var native: Object = wrapper.native
	native.index_updated.connect(func(_paths): updates += 1)
	await wait_ready(native)
	var before_updates := updates
	var before_buffers: int = wrapper._buffers.size()
	var document: Object = wrapper.get_disk_document(PATH, "var ignored: int\n")
	check(has_member(document, "saved") and not has_member(document, "ignored"), "indexed source wins over fallback")
	check(not document.sparse_parse().members.is_empty(), "indexed read has a sparse projection")
	revision = document.get_revision()
	var warm_stats: Dictionary = native.get_refresh_stats()
	for iteration in range(1000):
		check(wrapper.get_disk_document(PATH).get_revision() == revision, "repeated indexed reads retain revision")
		check(native.is_document_ready(PATH), "scratch reads preserve semantic readiness")
	check(native.get_refresh_stats().disk_reads == warm_stats.disk_reads, "1000 warm reads do not read file contents")
	await create_timer(0.05).timeout
	check(updates == before_updates, "scratch reads schedule no index updates")
	check(wrapper._buffers.size() == before_buffers and native.document(PATH) == null, "scratch reads register no buffers")

	var file := FileAccess.open(PATH, FileAccess.WRITE)
	file.store_string("extends RefCounted\nvar refreshed: String = \"disk\"\n")
	file.close()
	native.refresh_files(PackedStringArray([PATH]))
	await wait_ready(native, before_updates + 1)
	document = wrapper.get_disk_document(PATH)
	check(document.get_revision() != revision, "disk refresh changes read-only revision")
	check(has_member(document, "refreshed") and not has_member(document, "saved"), "disk refresh replaces cached structure")

	# A namespace rebuild shifts old members; reads must repair a missed notification immediately.
	var hub := "res://namespace_hub.gd"
	var old_source := "extends RefCounted\nconst Files = preload(\"res://fixture.gd\")\nconst Strings = preload(\"res://fixture.gd\")\nconst URNode = preload(\"res://fixture.gd\")\n"
	file = FileAccess.open(hub, FileAccess.WRITE)
	file.store_string(old_source)
	file.close()
	native.refresh_files(PackedStringArray([hub]))
	await wait_ready(native, updates + 1)
	var hub_doc: Object = wrapper.get_disk_document(hub)
	var old_revision: int = hub_doc.get_revision()
	var new_source := old_source.replace("const Strings", "const Nodes = 1\nconst Strings")
	file = FileAccess.open(hub, FileAccess.WRITE)
	file.store_string(new_source)
	file.close()
	hub_doc = wrapper.get_disk_document(hub, old_source)
	var constants: Dictionary = hub_doc.parse_script(hub)[""].constants
	check(constants.keys() == ["Files", "Nodes", "Strings", "URNode"], "missed notification preserves every namespace member")
	check(constants.Strings.line_index == 3 and constants.URNode.line_index == 4, "old namespace members move to their new lines")
	check(hub_doc.get_source_code() == new_source, "structural source matches the new declaration positions")
	check(hub_doc.get_revision() != old_revision, "missed notification advances structural revision immediately")
	old_revision = hub_doc.get_revision()
	await wait_ready(native, updates + 1)
	check(wrapper.get_disk_document(hub).get_revision() == old_revision, "semantic catch-up does not replace identical structure")
	before_updates = updates
	for iteration in range(5):
		check(wrapper.get_disk_document(hub).get_revision() == old_revision, "unchanged namespace reads keep revision")
	await create_timer(0.05).timeout
	check(updates == before_updates, "unchanged namespace reads schedule no refresh")

	# Explicit notifications invalidate even a matching metadata stamp.
	warm_stats = native.get_refresh_stats()
	before_updates = updates
	for iteration in range(20):
		wrapper._refresh_files(PackedStringArray([hub, hub]))
	hub_doc = wrapper.get_disk_document(hub)
	check(native.get_refresh_stats().disk_reads == warm_stats.disk_reads + 1, "notification forces one source check before the debounce expires")
	await wait_ready(native, before_updates + 1)
	check(native.get_refresh_stats().refresh_batches == warm_stats.refresh_batches + 1, "duplicate targeted notifications form one batch")
	check(native.get_refresh_stats().disk_scans == warm_stats.disk_scans, "targeted notifications do not scan the project")

	# High-resolution metadata detects equal-length edits within one second.
	new_source = new_source.replace("Nodes", "Other")
	file = FileAccess.open(hub, FileAccess.WRITE)
	file.store_string(new_source)
	file.close()
	hub_doc = wrapper.get_disk_document(hub)
	check(hub_doc.parse_script(hub)[""].constants.has("Other"), "same-size rapid rewrite changes structure")
	DirAccess.remove_absolute(hub)
	check(wrapper.get_disk_document(hub, old_source) == null, "deleted disk source does not revive stale fallback text")
	file = FileAccess.open(hub, FileAccess.WRITE)
	file.store_string(old_source)
	file.close()
	check(wrapper.get_disk_document(hub).get_source_code() == old_source, "recreated source replaces deletion")
	await wait_ready(native, updates + 1)
	wrapper._refresh_changed_sources()
	await wait_ready(native, updates + 1)
	file = FileAccess.open(hub, FileAccess.WRITE)
	file.store_string(new_source)
	file.close()
	var before_scan := updates
	warm_stats = native.get_refresh_stats()
	wrapper._queue_disk_scan()
	wrapper._queue_disk_scan()
	await wait_ready(native, before_scan + 1)
	check(native.get_refresh_stats().disk_scans == warm_stats.disk_scans + 1, "duplicate pathless notifications form one background scan")
	check(wrapper.get_disk_document(hub).get_source_code() == new_source, "coalesced filesystem scan refreshes changed source")
	DirAccess.remove_absolute(hub)
	wrapper._queue_disk_scan()
	await wait_ready(native, updates + 1)
	check(wrapper.get_disk_document(hub) == null, "filesystem scan refreshes deletion")

	var edit := CodeEdit.new()
	root.add_child(edit)
	edit.text = "extends RefCounted\nvar unsaved: bool = true\n"
	var manager := Manager.new()
	manager.attach(edit, PATH)
	document = wrapper.get_disk_document(PATH)
	check(document == manager.parser and has_member(document, "unsaved"), "live unsaved buffer wins immediately")
	check(document.get_revision() == manager.get_parse_revision(), "editor document version is unchanged")
	await wait_ready(native)
	file = FileAccess.open(PATH, FileAccess.WRITE)
	file.store_string("extends RefCounted\nvar refreshed: String = \"changed on disk\"\n")
	file.close()
	wrapper._refresh_changed_sources()
	check(wrapper.get_disk_document(PATH).get_source_code() == edit.text, "disk scan preserves unsaved source")
	before_updates = updates
	manager.detach()
	edit.free()
	await wait_ready(native, before_updates + 1)
	document = wrapper.get_disk_document(PATH)
	check(has_member(document, "refreshed") and not has_member(document, "unsaved"), "closing editor returns to saved source")

	revision = document.get_revision()
	native.open_workspace(ProjectSettings.globalize_path("res://"))
	await wait_ready(native)
	var reopened: Object = wrapper.get_disk_document(PATH)
	check(reopened != document and reopened.get_revision() != revision, "workspace reopen discards read-only projections")
	check(has_member(reopened, "refreshed"), "reopened workspace reads disk")
	check(wrapper.get_disk_document("") == null, "empty script path declines")
	# A wrapper paired with an older extension must decline cleanly.
	wrapper.native = RefCounted.new()
	check(wrapper.get_disk_document(PATH) == null, "older backend without document_for_path declines")
	wrapper.native = native
	wrapper.free()
	native = null
	if failures == 0:
		print("PASS: read-only structure, refresh, unsaved buffers and workspace lifecycle")
	quit(1 if failures else 0)
