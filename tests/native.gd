extends SceneTree

const Service = preload("res://addons/addon_lib/gdscript_lsp/service.gd")
const Manager = preload("res://addons/addon_lib/gdscript_lsp/code_edit_manager.gd")
var failures := 0
var service: Object
var revision := 0

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: " + message)

func _initialize() -> void:
	_run.call_deferred()

func update(source: String, uri := "res://fixture.gd") -> Object:
	revision += 1
	service.update_document(uri, source, revision)
	return service.document(uri)

func check_unattached(manager: RefCounted, label: String) -> void:
	check(not manager.is_attached(), label + " is unattached")
	check(manager.parser == null, label + " has no parser")
	check(not manager.cache_valid(), label + " has no valid cache")
	check(not manager.parse_text() and not manager.parse_text(true), label + " reports no change")
	check(manager.get_parse_revision() == -1 and manager.get_uri().is_empty(), label + " has no revision or URI")
	check(manager.parse() == {} and manager.sparse_parse() == {"members": {}, "lines": {}}, label + " returns empty projections")

func _run() -> void:
	service = ClassDB.instantiate(&"GDScriptLanguageService")
	# Direct structural reads require neither a workspace nor a scene-tree owner.
	var lambda_source := "var callbacks = [\"é😀\", func(): return func(): return 1]\n"
	for uri: String in ["res://structure.gd", "file://" + ProjectSettings.globalize_path("res://structure-file.gd"), "untitled:structure"]:
		var structural := update(lambda_source, uri)
		check(not service.is_ready() and not service.is_document_ready(uri), "semantic readiness is false without a workspace: " + uri)
		var projection: Dictionary = structural.parse_script(uri)
		check(projection[""].members.has("callbacks"), "structural members are immediately available: " + uri)
		check(not structural.sparse_parse().members.is_empty(), "sparse structure is immediately available: " + uri)
		var lambdas: Dictionary = projection[""].lambdas
		check(lambdas.size() == 1, "one outer lambda")
		for outer: Dictionary in lambdas.values():
			check([outer.get("line_index"), outer.get("column_index"), outer.get("end_line"), outer.get("end_column")] == [0, 27, 0, 58], "outer lambda uses zero-based UTF-8 byte columns and exclusive end")
			check(outer.has("lambdas") and outer.lambdas.size() == 1, "nested closures live under lambdas")
			for inner: Dictionary in outer.get("lambdas", {}).values():
				check([inner.get("line_index"), inner.get("column_index"), inner.get("end_line"), inner.get("end_column")] == [0, 42, 0, 58], "inner lambda preserves byte range keys")
		service.close_document(uri)
	var source := "enum { A, B, NEG = -3, NEXT }\nenum Named { FIRST, SECOND }\n@export var title: String = \"😀\"\nvar assigned = func(a: int) -> int: return a\nclass Inner:\n\tvar values = [1, (2)]\nfunc run(arg: int = 2):\n\tvar local = func(): return arg\n\tprint(arg)\n"
	var document := update(source)
	check(not service.is_ready(), "syntax works without opening a workspace")
	var full: Dictionary = document.parse_script("res://fixture.gd")
	check(full[""].constants.A.assignment == "0", "unnamed enum first value")
	check(full[""].constants.B.assignment == "A + 1", "unnamed enum increment")
	check(full[""].members.assigned.lambda.args.a.type == &"int", "typed lambda parameter")
	check(full[""].members.run.lambdas.size() == 1, "function lambda ownership")
	full[""].members.clear()
	check(not document.parse_script("res://fixture.gd")[""].members.is_empty(), "full projection is isolated from caller mutation")
	var members: Dictionary = document.sparse_parse().members
	document.set_bracket_mode(true)
	var brackets: Dictionary = document.get_brackets()
	var before: Dictionary = brackets.duplicate(true)
	document = update("\n" + source)
	check(document.sparse_parse().members == members, "line movement preserves member projection")
	check(brackets.get(6) == before.get(5), "retained bracket map shifts with inserted line")
	# Compare incremental brackets to a fresh parse over malformed/Unicode edits.
	var edits := [source, "\n" + source, source.replace("[1, (2)]", "[1, (2)"),
		source.replace("\"😀\"", "\"\"\"😀"), source.replace("print(arg)", "print(\"😀\", [arg])"), "", source]
	var old: Object
	if ClassDB.class_exists(&"GDScriptTreeParser"):
		old = ClassDB.instantiate(&"GDScriptTreeParser")
		old.set_bracket_mode(true)
	for text: String in edits:
		document = update(text)
		var fresh_service: Object = ClassDB.instantiate(&"GDScriptLanguageService")
		fresh_service.update_document("res://fixture.gd", text, 1)
		var fresh: Object = fresh_service.document("res://fixture.gd")
		fresh.set_bracket_mode(true)
		check(brackets == fresh.get_brackets(), "incremental and fresh brackets agree")
		if old != null:
			old.open_text(text)
			var legacy_full: Dictionary = old.parse_script("res://fixture.gd")
			var new_full: Dictionary = document.parse_script("res://fixture.gd")
			check(legacy_full.recursive_equal(new_full, 0), "legacy full structural parity")
			if not legacy_full.recursive_equal(new_full, 0) and text == source:
				FileAccess.open("res://legacy.json", FileAccess.WRITE).store_string(JSON.stringify(legacy_full, "  "))
				FileAccess.open("res://new.json", FileAccess.WRITE).store_string(JSON.stringify(new_full, "  "))
			check(old.sparse_parse().recursive_equal(document.sparse_parse(), 0), "legacy sparse parity")
			check(old.get_brackets() == brackets, "legacy bracket parity")
	document.set_bracket_mode(false)
	check(brackets.is_empty(), "disabling brackets clears retained reference")
	document.set_bracket_mode(true)
	check(not brackets.is_empty(), "reenabling brackets rebuilds retained reference")
	var open_state := {"ready": false, "error": false}
	service.workspace_ready.connect(func(): open_state.ready = true)
	service.workspace_error.connect(func(_message: String): open_state.error = true)
	check(service.open_workspace(ProjectSettings.globalize_path("res://")) == OK, "workspace opening starts successfully")
	check(not service.is_ready() and not open_state.ready, "workspace completion is asynchronous")
	document = update("var latest: int = 4\n")
	check(document.parse_script("res://fixture.gd")[""].members.has("latest"), "edits during indexing remain visible")
	for iteration in range(500):
		if service.is_document_ready("res://fixture.gd"):
			break
		await create_timer(0.01).timeout
	var symbols: Array = service.document_symbols("res://fixture.gd")
	check(open_state.ready and not open_state.error and service.is_ready(), "workspace success signal marks readiness")
	check(service.is_document_ready("res://fixture.gd"), "latest semantic revision becomes ready")
	check(str(symbols).contains("latest"), "semantic workspace ingests latest pre-ready snapshot")
	service.refresh_files(PackedStringArray(["res://fixture.gd"]))
	await create_timer(0.05).timeout
	check(str(service.document_symbols("res://fixture.gd")).contains("latest"), "disk refresh preserves open buffer")
	service.close_document("res://fixture.gd")
	check(brackets.is_empty(), "close clears retained brackets")
	check(Service.utf16_column("😀éabc", 2) == 3, "character to UTF-16 conversion")

	var failed: Object = ClassDB.instantiate(&"GDScriptLanguageService")
	var failure_state := {"seen": false, "ready": false}
	failed.workspace_error.connect(func(_message: String): failure_state.seen = true)
	failed.workspace_ready.connect(func(): failure_state.ready = true)
	check(failed.open_workspace(ProjectSettings.globalize_path("res://"), {"native_api_path": "res://missing-api.json"}) == OK, "OK does not imply successful indexing")
	failed.update_document("res://failed.gd", "var still_available = [1]\n", 1)
	for attempt in range(200):
		if failure_state.seen:
			break
		await create_timer(0.01).timeout
	check(failure_state.seen and not failure_state.ready and not failed.is_ready(), "indexing failure is reported without a success signal")
	check(failed.document("res://failed.gd").parse_script("res://failed.gd")[""].members.has("still_available"), "syntax survives indexing failure")
	failed = null

	var first: Node = Service.get_instance()
	check(first == Service.get_instance(), "singleton lookup shares one service")
	check(first.get_path() == NodePath("/root/GDScriptLSPService"), "runtime singleton attaches directly to root")
	var edit := CodeEdit.new()
	root.add_child(edit)
	var a := Manager.new()
	var b := Manager.new()
	check_unattached(a, "new manager")
	a.attach(edit, "res://shared.gd")
	b.attach(edit, "res://shared.gd")
	check(a.is_attached() and b.is_attached(), "empty buffers attach before semantic indexing")
	check(not first.native.is_ready(), "attachment does not wait for workspace opening")
	check(a.get_parse_revision() >= 0 and a.parse().has(""), "empty file has a real document")
	edit.text = source
	check(a.parser == b.parser, "consumers share one native document")
	var shared_revision := a.get_parse_revision()
	a.parse()
	b.sparse_parse()
	check(a.get_parse_revision() == shared_revision, "repeated reads do not reparse")
	edit.text = "\n" + source
	a.parse_text()
	check(b.get_parse_revision() != shared_revision, "other consumers still observe synchronized edit")
	a.parser.set_bracket_mode(true)
	var live: Dictionary = a.parser.get_brackets()
	a.detach()
	check_unattached(a, "detached manager")
	check(b.is_attached(), "other consumer remains attached")
	check(not live.is_empty() and b.parser != null, "one detach preserves another consumer")
	b.detach()
	check(live.is_empty(), "last detach clears brackets")
	a.attach(edit, "res://another.gd")
	check(a.get_parse_revision() > shared_revision, "reattachment uses monotonic revisions")
	a.set_script_path("")
	check(a.get_uri().begins_with("untitled:"), "unnamed buffer has a session identity")
	root.remove_child(edit)
	check_unattached(a, "CodeEdit removed from tree")
	root.add_child(edit)
	a.attach(edit, "")
	check(a.is_attached(), "same buffer can reattach after tree exit")
	edit.free()
	check_unattached(a, "freed CodeEdit")
	edit = CodeEdit.new()
	root.add_child(edit)
	a.attach(edit, "res://service-lifecycle.gd")
	first.free()
	check_unattached(a, "freed service")
	a.attach(edit, "res://service-lifecycle.gd")
	check(a.is_attached(), "same buffer can reattach to a replacement service")
	a.detach()
	edit.free()
	Service.get_instance().free()
	service = null
	if failures == 0:
		print("PASS: native structure, brackets, indexing, shared ownership and Unicode")
	quit(1 if failures else 0)
