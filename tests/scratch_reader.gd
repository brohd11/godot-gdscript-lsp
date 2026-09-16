extends SceneTree

# Run in a disposable integration project containing the GDScriptParser addon.
const DEPENDENCY := "res://scratch_dependency.gd"
const OWNER := "res://scratch_owner.gd"
var failures := 0

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: " + message)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for path: String in [DEPENDENCY, OWNER]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string("extends RefCounted\nconst VALUE: int = 7\n")
		file.close()
	var parser_script = load("res://addons/addon_lib/gdscript_parser/gdscript_parser.gd")
	var owner = parser_script.new()
	owner.active_parser = owner
	owner.set_parser_cache({})
	owner.set_parse_cache_dir("res://.godot/scratch-reader-cache")
	owner.set_current_script(load(OWNER))
	owner.set_source_code(load(OWNER).source_code)
	owner.parse()
	var service = load("res://addons/addon_lib/gdscript_lsp/service.gd").get_instance()
	for attempt in range(500):
		if service.native.is_document_ready(OWNER):
			break
		await create_timer(0.01).timeout
	check(service.native.is_document_ready(OWNER), "owner index becomes ready")
	var buffers: int = service._buffers.size()
	var updates := {"count": 0}
	service.native.index_updated.connect(func(_paths): updates.count += 1)
	var scratch = owner.get_parser_for_path(DEPENDENCY, true)
	check(scratch != null and scratch.active_parser == owner, "dependency reader carries its active parser")
	check(scratch.get_class_object().use_ts, "scratch reader actually uses native structure")
	check(not is_instance_valid(scratch.code_edit_parser.native_manager), "scratch reader has no editor manager")
	check(scratch.get_class_object().get_member_type_rich("VALUE").type == "int", "GDScript type lookup still resolves scratch members")
	await create_timer(0.05).timeout
	check(service._buffers.size() == buffers and updates.count == 0, "dependency lookup registers no buffer or indexing work")
	check(service.native.is_document_ready(OWNER), "dependency lookup preserves owner readiness")
	# Parser-created CodeEdits can still be live editor buffers.
	owner.code_edit.text = "extends RefCounted\nvar edited: String\n"
	owner.parse()
	check(owner.get_class_object().get_member_data("edited").member_name == &"edited", "parser-created live buffer remains editable")
	# Simulate an installed service script predating the read-only helper.
	service.name = "CurrentService"
	var old_service := Node.new()
	old_service.name = "GDScriptLSPService"
	root.add_child(old_service)
	var fallback = parser_script.new()
	fallback.active_parser = owner
	fallback.set_current_script(load(DEPENDENCY))
	fallback.set_source_code(load(DEPENDENCY).source_code)
	fallback.parse()
	check(not fallback.get_class_object().use_ts, "older service uses text parsing for scratch readers")
	check(fallback.get_class_object().get_member_type_rich("VALUE").type == "int", "text fallback preserves type resolution")
	old_service.free()
	service.name = "GDScriptLSPService"
	for parser in [fallback, scratch, owner]:
		if is_instance_valid(parser.code_edit_parser.native_manager):
			parser.code_edit_parser.native_manager.detach()
		parser.active_parser = null
		parser.set_parser_cache({})
		if is_instance_valid(parser.code_edit):
			parser.code_edit.free()
	fallback = null
	scratch = null
	owner = null
	service.free()
	if failures == 0:
		print("PASS: scratch reader integration, live edits and older-service fallback")
	quit(1 if failures else 0)
