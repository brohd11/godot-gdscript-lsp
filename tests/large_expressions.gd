extends SceneTree

var service: Object
var opened := false
var open_error := ""
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: " + message)

func wait_for_document(uri: String) -> bool:
	for attempt in range(2000):
		if service.is_document_ready(uri):
			return true
		await create_timer(0.01).timeout
	check(false, "wide document revision became ready")
	return false

func find_symbol(symbols: Array, name: String) -> Dictionary:
	for symbol: Dictionary in symbols:
		if symbol.get("name") == name:
			return symbol
		var found := find_symbol(symbol.get("children", []), name)
		if not found.is_empty():
			return found
	return {}

func _run() -> void:
	service = ClassDB.instantiate(&"GDScriptLanguageService")
	check(service != null, "native service is available")
	if service == null:
		quit(1)
		return
	service.workspace_ready.connect(func(): opened = true)
	service.workspace_error.connect(func(message: String): open_error = message)
	check(service.open_workspace("res://tests/fixtures/large_expressions") == OK, "indexing started")
	for attempt in range(2000):
		if opened or not open_error.is_empty():
			break
		await create_timer(0.01).timeout
	check(opened and open_error.is_empty() and service.is_ready(), "workspace_ready after indexing wide fixture: " + open_error)
	if not opened:
		service = null
		quit(1)
		return
	var uri := "res://limits.gd"
	if await wait_for_document(uri):
		var symbols: Array = service.document_symbols(uri)
		for name: String in ["depth_0", "wide", "deep", "shallow", "oversized"]:
			check(not find_symbol(symbols, name).is_empty(), "indexed method: " + name)
		check(service.diagnostics(uri).is_empty(), "fixture has no diagnostics")
		check(service.resolve_type(uri, 87, 0, "wide(1)").get("name") == "int", "wide retains int return type")
	var terms := PackedStringArray()
	terms.resize(8192)
	terms.fill("value")
	var source := "extends RefCounted\nstatic func wide(value: int) -> int:\n\treturn " + " + ".join(terms) + "\n"
	service.update_document(uri, source, 1)
	if await wait_for_document(uri):
		check(service.diagnostics(uri).is_empty(), "8192-term update has no diagnostics")
		check(not find_symbol(service.document_symbols(uri), "wide").is_empty(), "wide update is indexed")
	service.update_document(uri, "extends RefCounted\nfunc later() -> int:\n\treturn 1\n", 2)
	if await wait_for_document(uri):
		check(not find_symbol(service.document_symbols(uri), "later").is_empty(), "subsequent update completes")
	service.close_document(uri)
	# Releasing the service joins the worker and destroys its document trees.
	service = null
	print("Large expression native tests: ", failures, " failure(s)")
	quit(1 if failures else 0)
