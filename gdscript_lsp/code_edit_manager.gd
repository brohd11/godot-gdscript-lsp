@tool
class_name GDScriptLSPCodeEditManager
extends RefCounted

const Service = preload("res://addons/addon_lib/gdscript_lsp/service.gd")
var _service: Node
var _edit: CodeEdit
var _script_path := ""
var _key := ""
var _seen_revision := -1
var parser: Object:
	get:
		return _service.get_document(_key) if is_instance_valid(_service) else null

func attach(edit: CodeEdit, script_path := "") -> void:
	if _edit == edit and _script_path == script_path and not _key.is_empty():
		return
	detach()
	_service = Service.get_instance()
	if not is_instance_valid(_service):
		return
	_edit = edit
	_script_path = script_path
	_key = _service.acquire(edit, script_path)
	_seen_revision = -1

func detach() -> void:
	if is_instance_valid(_service) and not _key.is_empty():
		_service.release(_key)
	_key = ""
	_edit = null
	_seen_revision = -1

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_service) and not _key.is_empty():
		_service.release(_key)

func set_script_path(script_path: String) -> void:
	if script_path != _script_path and is_instance_valid(_edit):
		attach(_edit, script_path)

func cache_valid() -> bool:
	if not is_instance_valid(_service) or _key.is_empty():
		return false
	return _service.sync_buffer(_key) == _seen_revision

func parse_text(force := false) -> bool:
	if not is_instance_valid(_service) or _key.is_empty():
		return false
	var revision: int = _service.sync_buffer(_key, force)
	var changed := revision != _seen_revision
	_seen_revision = revision
	return changed

func get_parse_revision() -> int:
	return _service.sync_buffer(_key) if is_instance_valid(_service) else -1

func get_uri() -> String:
	return _service.get_uri(_key) if is_instance_valid(_service) else ""

func parse() -> Dictionary:
	parse_text()
	return parser.parse_script(_script_path) if is_instance_valid(parser) else {}

func sparse_parse() -> Dictionary:
	parse_text()
	return parser.sparse_parse() if is_instance_valid(parser) else {"members": {}, "lines": {}}
