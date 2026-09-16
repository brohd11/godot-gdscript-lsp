@tool
class_name GDScriptLSPService
extends Node

## One shared service per scene tree. This script has no AddonLib dependencies.
const SCRIPT_PATH := "res://addons/addon_lib/gdscript_lsp/service.gd"
var native: Object
var _buffers: Dictionary = {}
var _revision := 0

static func available() -> bool:
	return ClassDB.class_exists(&"GDScriptLanguageService")

static func get_instance() -> Node:
	if not available():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var parent: Node = tree.root
	if Engine.is_editor_hint():
		var editor: Node
		for child in tree.root.get_children():
			if child.get_class() == "EditorNode" or child.name == &"EditorNode":
				editor = child
				break
		if editor == null:
			return null
		parent = editor.get_node_or_null("EditorSingletons")
		if parent == null:
			parent = Node.new()
			parent.name = &"EditorSingletons"
			editor.add_child(parent)
	var service := parent.get_node_or_null("GDScriptLSPService")
	if service == null:
		service = load(SCRIPT_PATH).new()
		service.name = &"GDScriptLSPService"
		parent.add_child(service)
	return service

func _ready() -> void:
	native = ClassDB.instantiate(&"GDScriptLanguageService")
	native.open_workspace(ProjectSettings.globalize_path("res://"))
	if Engine.is_editor_hint():
		var filesystem := EditorInterface.get_resource_filesystem()
		filesystem.resources_reload.connect(_refresh_files)
		filesystem.resources_reimported.connect(_refresh_files)

func acquire(edit: CodeEdit, script_path: String) -> String:
	var key := "%s:%s" % [edit.get_instance_id(), script_path]
	if _buffers.has(key):
		_buffers[key].users += 1
		return key
	var uri := script_path
	if uri.is_empty() or uri.contains("::"):
		uri = "untitled:gdscript-lsp/%s" % key
	_buffers[key] = {"edit": weakref(edit), "uri": uri, "users": 1,
		"version": -1, "revision": -1, "source": "", "initialized": false}
	edit.text_changed.connect(_changed.bind(key))
	edit.text_set.connect(_replaced.bind(key))
	edit.tree_exiting.connect(_editor_exiting.bind(key))
	sync_buffer(key)
	return key

func _changed(key: String) -> void:
	sync_buffer(key)

func _replaced(key: String) -> void:
	sync_buffer(key, true)

func _editor_exiting(key: String) -> void:
	_discard(key)

func sync_buffer(key: String, force := false) -> int:
	if not _buffers.has(key):
		return -1
	var record: Dictionary = _buffers[key]
	var edit: CodeEdit = record.edit.get_ref()
	if not is_instance_valid(edit):
		_discard(key)
		return -1
	var version := edit.get_version()
	if not force and record.initialized and record.version == version:
		return record.revision
	var source := edit.text
	record.version = version
	if record.initialized and record.source == source:
		return record.revision
	_revision += 1
	record.revision = _revision
	record.source = source
	record.initialized = true
	native.update_document(record.uri, source, _revision)
	return _revision

func get_document(key: String) -> Object:
	if not _buffers.has(key):
		return null
	return native.document(_buffers[key].uri)

## Read-only structural view of a script as the workspace indexed it, for callers that only want to
## READ another file. Unlike acquire(), this registers no buffer, pushes no document version and
## invalidates nothing - so it cannot disturb the semantic index of scripts that depend on it.
## Returns null when the extension predates document_for_path, so callers must handle a null.
## `text` is only a fallback for files the workspace has not indexed yet (open_workspace is async);
## when it has, the indexed copy wins and the text is ignored.
func get_disk_document(script_path: String, text := "") -> Object:
	if not is_instance_valid(native) or script_path.is_empty() or script_path.contains("::"):
		return null
	if not native.has_method(&"document_for_path"):
		return null
	return native.document_for_path(script_path, text)

func get_uri(key: String) -> String:
	return _buffers.get(key, {}).get("uri", "")

func release(key: String) -> void:
	if not _buffers.has(key):
		return
	_buffers[key].users -= 1
	if _buffers[key].users <= 0:
		_discard(key)

func _discard(key: String) -> void:
	if not _buffers.has(key):
		return
	var record: Dictionary = _buffers[key]
	var edit: CodeEdit = record.edit.get_ref()
	if is_instance_valid(edit):
		for pair in [[edit.text_changed, _changed.bind(key)], [edit.text_set, _replaced.bind(key)],
			[edit.tree_exiting, _editor_exiting.bind(key)]]:
			if pair[0].is_connected(pair[1]):
				pair[0].disconnect(pair[1])
	_buffers.erase(key)
	for other: Dictionary in _buffers.values():
		if other.uri == record.uri:
			return
	native.close_document(record.uri)

func _refresh_files(paths: PackedStringArray) -> void:
	native.refresh_files(paths)

func _exit_tree() -> void:
	for key: String in _buffers.keys():
		_discard(key)
	native = null

static func utf16_column(line: String, character_column: int) -> int:
	var result := 0
	for index in range(mini(character_column, line.length())):
		result += 2 if line.unicode_at(index) > 0xffff else 1
	return result
