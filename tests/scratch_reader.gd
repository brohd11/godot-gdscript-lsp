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
	for path: String in ["res://scratch_target.gd", DEPENDENCY, OWNER]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string("extends RefCounted\nconst VALUE: int = 7\n" + ("const URString = preload(\"res://scratch_target.gd\")\n" if path == DEPENDENCY else ""))
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
	var warm_stats: Dictionary = service.native.get_refresh_stats()
	var started := Time.get_ticks_usec()
	for iteration in range(1000):
		check(owner.get_parser_for_path(DEPENDENCY) == scratch, "warm lookup retains parser")
	check(service.native.get_refresh_stats().disk_reads == warm_stats.disk_reads, "1000 warm parser lookups read no source files")
	print("PERF: 1000 warm parser lookups: %.2f ms; source reads: 0" % ((Time.get_ticks_usec() - started) / 1000.0))
	# Populate both caches, then move existing namespace members without reloading resources.
	var hub := "res://scratch_namespace.gd"
	var original := "extends RefCounted\nconst Files = preload(\"res://scratch_dependency.gd\")\nconst Strings = preload(\"res://scratch_dependency.gd\")\nconst URNode = preload(\"res://scratch_dependency.gd\")\nconst UROs = preload(\"res://scratch_dependency.gd\")\n"
	var file := FileAccess.open(hub, FileAccess.WRITE)
	file.store_string(original)
	file.close()
	var hub_parser = owner.get_parser_for_path(hub, true)
	check(hub_parser.get_class_object().get_gdscript_constants() == ["Files", "Strings", "URNode", "UROs"], "original namespace resolves every constant")
	check(hub_parser.write_cache(), "namespace cache is populated")
	var restored = owner.read_cache(hub)
	var replacement := original.replace("const Strings", "const Nodes = preload(\"res://scratch_dependency.gd\")\nconst Strings")
	file = FileAccess.open(hub, FileAccess.WRITE)
	file.store_string(replacement)
	file.close()
	check(not hub_parser.write_cache(), "stale structure cannot be stamped with the current disk source")
	check(owner.read_cache(hub) == null, "same-second disk change invalidates persistent cache")
	hub_parser = owner.get_parser_for_path(hub)
	check(hub_parser.code_edit.text == replacement, "reader uses current disk source despite the loaded resource")
	check(hub_parser.get_class_object().get_gdscript_constants() == ["Files", "Nodes", "Strings", "URNode", "UROs"], "shifted old members remain available to completions")
	for member: String in ["Strings", "URNode", "UROs"]:
		check(hub_parser.resolve_expression_to_type(member, 0) == DEPENDENCY, "shifted " + member + " resolves to its script")
	check(hub_parser.resolve_expression_to_type("Strings.URString", 0) == "res://scratch_target.gd", "nested resolve survives namespace rebuild")
	check(hub_parser.write_cache(), "repaired structure persists")
	var repaired = owner.read_cache(hub)
	check(repaired.get_class_object().get_gdscript_constants() == ["Files", "Nodes", "Strings", "URNode", "UROs"], "restored cache retains old namespace members")
	# A disk cache loaded before the rewrite must also attach current source on a miss.
	check(restored.resolve_expression_to_type("Strings.URString", 0) == "res://scratch_target.gd", "old rehydrated parser upgrades before reading changed source")
	for temporary in [restored, repaired, hub_parser]:
		if is_instance_valid(temporary.code_edit):
			temporary.code_edit.free()
		temporary.active_parser = null
	restored = null
	repaired = null
	hub_parser = null

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
