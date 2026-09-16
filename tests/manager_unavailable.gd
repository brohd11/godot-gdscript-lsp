extends SceneTree

const Manager = preload("res://addons/addon_lib/gdscript_lsp/code_edit_manager.gd")
var failures := 0

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: " + message)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	check(not ClassDB.class_exists(&"GDScriptLanguageService"), "extension is absent")
	var edit := CodeEdit.new()
	root.add_child(edit)
	var manager := Manager.new()
	manager.attach(edit, "res://empty.gd")
	check(not manager.is_attached() and manager.parser == null, "missing backend cannot attach")
	check(not manager.cache_valid(), "missing backend has no valid cache")
	check(not manager.parse_text() and not manager.parse_text(true), "missing backend reports no change")
	check(manager.get_parse_revision() == -1, "missing backend has no revision")
	check(manager.get_uri().is_empty(), "missing backend has no URI")
	check(manager.parse() == {}, "missing backend has no full projection")
	check(manager.sparse_parse() == {"members": {}, "lines": {}}, "missing backend has empty sparse projection")
	manager.detach()
	edit.free()
	if failures == 0:
		print("PASS: manager without native extension")
	quit(1 if failures else 0)
