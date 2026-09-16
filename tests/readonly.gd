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
	for iteration in range(10):
		check(wrapper.get_disk_document(PATH).get_revision() == revision, "repeated indexed reads retain revision")
		check(native.is_document_ready(PATH), "scratch reads preserve semantic readiness")
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

	var edit := CodeEdit.new()
	root.add_child(edit)
	edit.text = "extends RefCounted\nvar unsaved: bool = true\n"
	var manager := Manager.new()
	manager.attach(edit, PATH)
	document = wrapper.get_disk_document(PATH)
	check(document == manager.parser and has_member(document, "unsaved"), "live unsaved buffer wins immediately")
	check(document.get_revision() == manager.get_parse_revision(), "editor document version is unchanged")
	await wait_ready(native)
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
