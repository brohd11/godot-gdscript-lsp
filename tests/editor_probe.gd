@tool
extends EditorPlugin


func _enter_tree() -> void:
	_check.call_deferred()


func _check() -> void:
	await get_tree().create_timer(3.0).timeout
	var singleton = load("res://addons/code_completions/src/class/editor_code_completion_singleton.gd").get_instance()
	var provider = singleton.native_completion
	if not is_instance_valid(provider):
		_fail("Native completion provider was not registered")
		return
	var owner: Node
	for child in get_tree().root.get_children():
		if child.get_class() == "EditorNode":
			owner = child.get_node_or_null("EditorSingletons/GDScriptLSPService")
	if ClassDB.class_exists(&"GDScriptLanguageService"):
		if not is_instance_valid(owner) or provider._owner != owner or provider._service != owner.native:
			_fail("Completion provider did not acquire the shared service (owner=%s, provider owner=%s, native=%s)" % [owner, provider._owner, provider._service])
			return
	elif is_instance_valid(owner) or is_instance_valid(provider._service):
		_fail("Native-absent provider did not fall through")
		return
	print("PASS: editor consumer initialization")
	get_tree().quit()


func _fail(message: String) -> void:
	push_error("FAIL: " + message)
	get_tree().quit(1)
