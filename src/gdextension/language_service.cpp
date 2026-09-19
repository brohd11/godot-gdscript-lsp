#include "gdextension/language_service.hpp"
#include "core/uri.hpp"

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <fstream>
#include <iterator>

using namespace godot;

namespace gdscript_lsp {
namespace {

std::string to_std(const String &value) {
	CharString utf8 = value.utf8();
	return std::string(utf8.get_data(), static_cast<size_t>(utf8.length()));
}

String to_godot(std::string_view value) {
	return String::utf8(value.data(), static_cast<int64_t>(value.size()));
}

Dictionary position_dict(Position value) {
	Dictionary result;
	result["line"] = static_cast<int64_t>(value.line);
	result["character"] = static_cast<int64_t>(value.character);
	return result;
}

Dictionary range_dict(Range value) {
	Dictionary result;
	result["start"] = position_dict(value.start);
	result["end"] = position_dict(value.end);
	return result;
}

Dictionary type_dict(const ResolvedType &type) {
	Dictionary result;
	result["kind"] = to_godot(type_kind_name(type.kind));
	result["name"] = to_godot(type.name);
	result["display"] = to_godot(type.display());
	result["symbolId"] = to_godot(type.symbol_id);
	result["instance"] = type.instance;
	Array arguments;
	for (const auto &argument : type.arguments) arguments.push_back(type_dict(argument));
	result["arguments"] = arguments;
	return result;
}

Dictionary origin_dict(const SymbolOrigin &origin) {
	Dictionary result;
	result["symbolId"] = to_godot(origin.symbol_id);
	result["uri"] = to_godot(origin.uri);
	result["ownerId"] = to_godot(origin.owner_id);
	result["name"] = to_godot(origin.name);
	result["kind"] = static_cast<int64_t>(origin.kind);
	result["range"] = range_dict(origin.range);
	return result;
}

Dictionary expression_dict(const ResolvedExpression &expression) {
	Dictionary result;
	result["type"] = type_dict(expression.type);
	result["origin"] = expression.origin ? Variant(origin_dict(*expression.origin)) : Variant();
	Array paths;
	for (const auto &path : expression.access_paths) {
		Dictionary value;
		value["text"] = to_godot(path.text);
		value["kind"] = to_godot(access_path_kind_name(path.kind));
		value["preferred"] = path.preferred;
		paths.push_back(value);
	}
	result["accessPaths"] = paths;
	return result;
}

Dictionary outline_symbol_dict(const OutlineSymbol &symbol) {
	Dictionary result;
	result["symbolId"] = to_godot(symbol.symbol_id);
	result["ownerId"] = to_godot(symbol.owner_id);
	result["name"] = to_godot(symbol.name);
	result["detail"] = to_godot(symbol.detail);
	result["kind"] = static_cast<int64_t>(symbol.kind);
	result["range"] = range_dict(symbol.range);
	result["selectionRange"] = range_dict(symbol.selection_range);
	result["resolvedType"] = type_dict(symbol.resolved_type);
	result["returnType"] = symbol.return_type ? Variant(type_dict(*symbol.return_type)) : Variant();
	result["origin"] = symbol.origin ? Variant(origin_dict(*symbol.origin)) : Variant();
	Dictionary flags;
	flags["static"] = symbol.is_static;
	flags["staticTyped"] = symbol.static_typed;
	flags["inferred"] = symbol.inferred;
	flags["local"] = symbol.is_local;
	flags["parameter"] = symbol.is_parameter;
	flags["variadic"] = symbol.is_variadic;
	flags["malformed"] = symbol.malformed;
	result["flags"] = flags;
	Array children;
	for (const auto &child : symbol.children) children.push_back(outline_symbol_dict(child));
	if (!children.is_empty()) result["children"] = children;
	return result;
}

Dictionary diagnostic_dict(const Diagnostic &diagnostic) {
	Dictionary result;
	result["code"] = to_godot(diagnostic.code);
	result["message"] = to_godot(diagnostic.message);
	result["severity"] = static_cast<int64_t>(diagnostic.severity);
	result["source"] = to_godot(diagnostic.source);
	result["range"] = range_dict(diagnostic.range);
	Array related;
	for (const auto &item : diagnostic.related_information) {
		Dictionary value;
		value["uri"] = to_godot(item.location.uri);
		value["range"] = range_dict(item.location.range);
		value["message"] = to_godot(item.message);
		related.push_back(value);
	}
	result["relatedInformation"] = related;
	return result;
}

PackedStringArray packed_paths(const std::vector<std::string> &values) {
	PackedStringArray paths;
	for (const auto &value : values) paths.push_back(to_godot(value));
	return paths;
}

String disposition_name(CompletionDisposition disposition) {
	switch (disposition) {
		case CompletionDisposition::Augment: return "augment";
		case CompletionDisposition::Replace: return "replace";
		default: return "not_handled";
	}
}

Dictionary completion_dict(const CompletionResult &completion) {
	Dictionary result;
	Array items;
	for (const auto &item : completion.items) {
		Dictionary value;
		value["label"] = to_godot(item.label);
		value["detail"] = to_godot(item.detail);
		value["documentation"] = to_godot(item.documentation);
		value["kind"] = static_cast<int64_t>(item.kind);
		value["insertText"] = to_godot(item.insert_text);
		value["filterText"] = to_godot(item.filter_text);
		value["sortText"] = to_godot(item.sort_text);
		Dictionary extension;
		extension["symbolId"] = to_godot(item.symbol_id);
		extension["originId"] = to_godot(item.origin_id);
		extension["provider"] = to_godot(item.provider);
		extension["accessKind"] = to_godot(item.access_kind);
		Dictionary data;
		data["gdscriptLsp"] = extension;
		value["data"] = data;
		items.push_back(value);
	}
	result["isIncomplete"] = completion.is_incomplete;
	result["disposition"] = disposition_name(completion.disposition);
	result["provider"] = to_godot(completion.provider);
	result["items"] = items;
	return result;
}

} // namespace

std::optional<GDScriptLanguageService::DiskStamp> GDScriptLanguageService::disk_stamp(const std::filesystem::path &path) {
	std::error_code error;
	DiskStamp stamp;
	stamp.exists = std::filesystem::exists(path, error);
	if (error) return {};
	if (!stamp.exists) return stamp;
	stamp.modified = std::filesystem::last_write_time(path, error);
	if (error) return {};
	stamp.size = std::filesystem::file_size(path, error);
	if (error) return {};
	return stamp;
}

GDScriptLanguageService::DiskStamps GDScriptLanguageService::scan_disk_stamps(const std::filesystem::path &root, std::stop_token stop) {
	DiskStamps result;
	std::error_code error;
	for (std::filesystem::recursive_directory_iterator it(root, std::filesystem::directory_options::skip_permission_denied, error), end;
			it != end && !stop.stop_requested(); it.increment(error)) {
		if (error) { error.clear(); continue; }
		const auto &path = it->path();
		if (it->is_directory(error)) {
			if (path.filename() == ".git" || std::filesystem::exists(path / ".gdignore", error)) it.disable_recursion_pending();
			continue;
		}
		if (path.extension() != ".gd" && !path.string().ends_with(".gd.uid") && path != root / "project.godot") continue;
		if (auto stamp = disk_stamp(path)) result[file_uri_for_path(path)] = *stamp;
	}
	return result;
}

GDScriptLanguageService::GDScriptLanguageService() : workspace_(std::make_unique<Workspace>()) {}

std::string GDScriptLanguageService::target_uri(const String &uri) const {
	if (uri.begins_with("res://")) return file_uri_for_path(project_root_ / to_std(uri.substr(6)));
	auto value = to_std(uri);
	return canonical_file_uri(value).value_or(value);
}

bool GDScriptLanguageService::current(const String &uri) const {
	if (!ready_ || semantic_busy_) return false;
	auto target = target_uri(uri);
	std::lock_guard queue_lock(queue_mutex_);
	if (configuration_pending_ || pending_.contains(target) || closes_.contains(target) || refreshes_.contains(target)) return false;
	auto found = documents_.find(target);
	return found == documents_.end() || workspace_->document_version(target) == found->second->get_revision();
}

bool GDScriptLanguageService::is_document_ready(const String &uri) const {
	std::unique_lock lock(semantic_mutex_, std::try_to_lock);
	return lock.owns_lock() && current(uri);
}

Ref<GDScriptLSPDocument> GDScriptLanguageService::document(const String &uri) const {
	auto found = documents_.find(target_uri(uri));
	return found == documents_.end() ? Ref<GDScriptLSPDocument>() : found->second;
}

Ref<GDScriptLSPDocument> GDScriptLanguageService::document_for_path(const String &uri,
		const String &text) {
	auto target = target_uri(uri);
	// Open editor buffers carry unsaved text and always take precedence.
	if (auto open = documents_.find(target); open != documents_.end()) return open->second;

	auto file_path = path_for_file_uri(target);
	std::optional<DiskStamp> stamp;
	if (!project_root_.empty() && file_path) {
		stamp = disk_stamp(*file_path);
		if (!stamp) return {};
		auto known = readonly_stamps_.find(target);
		auto document = readonly_documents_.find(target);
		if (known != readonly_stamps_.end() && known->second == *stamp && document != readonly_documents_.end())
			return document->second;
	}
	auto snapshot = workspace_->document_snapshot(target);
	std::optional<std::string> source;
	if (!project_root_.empty() && file_path) {
		std::error_code error;
		const bool exists = std::filesystem::exists(*file_path, error);
		if (error) return {};
		if (exists) {
			++disk_reads_;
			std::ifstream file(*file_path, std::ios::binary);
			if (!file) return {};
			source = std::string(std::istreambuf_iterator<char>(file), {});
			if (file.bad()) return {};
		}
		const bool matches = snapshot && source && snapshot->source() == *source;
		if (matches) {
			requested_disk_sources_.erase(target);
		} else if (snapshot || source || readonly_documents_.contains(target)) {
			auto requested = requested_disk_sources_.find(target);
			if (requested == requested_disk_sources_.end() || requested->second != source) {
				requested_disk_sources_[target] = source;
				refresh_files(PackedStringArray{uri});
			}
		}
		if (!source) {
			readonly_documents_.erase(target);
			return {};
		}
	} else if (snapshot) {
		source = snapshot->source();
	} else if (!text.is_empty()) {
		source = to_std(text);
	} else {
		return {};
	}

	auto &entry = readonly_documents_[target];
	if (entry.is_null()) entry.instantiate();
	// Keep a newer structural read while the asynchronous index still has old text.
	if (!entry->snapshot() || entry->snapshot()->source() != *source) {
		if (snapshot && snapshot->source() == *source) {
			entry->set_snapshot(std::move(snapshot), readonly_revision_--);
		} else {
			auto path = file_path ? "res://" + file_path->lexically_relative(project_root_).generic_string() : to_std(uri);
			entry->set_snapshot(std::make_shared<Document>(target, path, std::move(*source), -1,
				Document::Analysis::Deferred), readonly_revision_--);
		}
	}
	// A write racing this read must be checked again on the next lookup.
	if (stamp && disk_stamp(*file_path) == stamp) readonly_stamps_[target] = *stamp;
	else readonly_stamps_.erase(target);
	return entry;
}

GDScriptLanguageService::~GDScriptLanguageService() {
	if (index_thread_.joinable()) {
		index_thread_.request_stop();
		queue_changed_.notify_all();
		index_thread_.join();
	}
}

void GDScriptLanguageService::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open_workspace", "project_root", "options"),
		&GDScriptLanguageService::open_workspace, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("is_ready"), &GDScriptLanguageService::is_ready);
	ClassDB::bind_method(D_METHOD("update_document", "uri", "text", "version"),
		&GDScriptLanguageService::update_document);
	ClassDB::bind_method(D_METHOD("is_document_ready", "uri"), &GDScriptLanguageService::is_document_ready);
	ClassDB::bind_method(D_METHOD("document", "uri"), &GDScriptLanguageService::document);
	ClassDB::bind_method(D_METHOD("close_document", "uri"), &GDScriptLanguageService::close_document);
	ClassDB::bind_method(D_METHOD("refresh_files", "paths", "scan"), &GDScriptLanguageService::refresh_files, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("invalidate_files", "paths"), &GDScriptLanguageService::invalidate_files);
	ClassDB::bind_method(D_METHOD("request_disk_scan"), &GDScriptLanguageService::request_disk_scan);
	ClassDB::bind_method(D_METHOD("get_refresh_stats"), &GDScriptLanguageService::get_refresh_stats);
	ClassDB::bind_method(D_METHOD("completion", "uri", "line", "utf16_column"),
		&GDScriptLanguageService::completion);
	ClassDB::bind_method(D_METHOD("completion_ex", "uri", "line", "utf16_column", "options"),
		&GDScriptLanguageService::completion_ex, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("set_configuration", "configuration"),
		&GDScriptLanguageService::set_configuration);
	ClassDB::bind_method(D_METHOD("hover", "uri", "line", "utf16_column"),
		&GDScriptLanguageService::hover);
	ClassDB::bind_method(D_METHOD("definition", "uri", "line", "utf16_column"),
		&GDScriptLanguageService::definition);
	ClassDB::bind_method(D_METHOD("document_symbols", "uri"), &GDScriptLanguageService::document_symbols);
	ClassDB::bind_method(D_METHOD("diagnostics", "uri"), &GDScriptLanguageService::diagnostics);
	ClassDB::bind_method(D_METHOD("document_for_path", "uri", "text"),
		&GDScriptLanguageService::document_for_path, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("resolve_type", "uri", "line", "utf16_column", "expression"),
		&GDScriptLanguageService::resolve_type, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("resolve_expression", "uri", "line", "utf16_column", "expression"),
		&GDScriptLanguageService::resolve_expression, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("_finish_open", "generation", "error"), &GDScriptLanguageService::_finish_open);
	ClassDB::bind_method(D_METHOD("_finish_update", "generation", "paths"), &GDScriptLanguageService::_finish_update);
	ADD_SIGNAL(MethodInfo("workspace_ready"));
	ADD_SIGNAL(MethodInfo("workspace_error", PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("index_updated", PropertyInfo(Variant::PACKED_STRING_ARRAY, "paths")));
	ADD_SIGNAL(MethodInfo("diagnostics_updated", PropertyInfo(Variant::PACKED_STRING_ARRAY, "paths")));
}

Error GDScriptLanguageService::open_workspace(const String &project_root, const Dictionary &options) {
	if (index_thread_.joinable()) {
		index_thread_.request_stop();
		queue_changed_.notify_all();
		index_thread_.join();
	}
	readonly_documents_.clear();
	readonly_stamps_.clear();
	requested_disk_sources_.clear();
	ready_ = false;
	semantic_busy_ = false;
	++generation_;
	String root = project_root;
	if (root.begins_with("res://")) root = ProjectSettings::get_singleton()->globalize_path(root);
	const std::filesystem::path next_root = to_std(root);
	if (next_root.lexically_normal() != project_root_.lexically_normal()) {
		for (auto &[uri, doc] : documents_) doc->clear_brackets();
		documents_.clear();
	}
	project_root_ = next_root;
	if (options.has("configuration")) set_configuration(options["configuration"]);
	String api = options.get("native_api_path", "res://addons/addon_lib/gdscript_lsp/data/godot-4.6-extension-api.json");
	if (api.begins_with("res://")) api = ProjectSettings::get_singleton()->globalize_path(api);
	{
		std::lock_guard lock(queue_mutex_);
		pending_.clear(); closes_.clear(); refreshes_.clear(); scan_pending_ = false;
		for (const auto &[uri, doc] : documents_) pending_[uri] = doc->snapshot();
		configuration_pending_ = true;
	}
	index_thread_ = std::jthread([this, root_value = project_root_, api_value = to_std(api), generation = generation_](std::stop_token stop) {
		auto disk_stamps = scan_disk_stamps(root_value, stop);
		++disk_scans_;
		std::string error;
		{
			std::lock_guard semantic_lock(semantic_mutex_);
			workspace_->open(root_value, api_value, &error);
		}
		if (stop.stop_requested()) return;
		call_deferred("_finish_open", generation, to_godot(error));
		if (!error.empty()) return;
		while (!stop.stop_requested()) {
			decltype(pending_) pending;
			decltype(closes_) closes, refreshes;
			CompletionConfig configuration;
			bool configure, scan;
			{
				std::unique_lock lock(queue_mutex_);
				queue_changed_.wait(lock, stop, [this] {
					return !pending_.empty() || !closes_.empty() || !refreshes_.empty() || configuration_pending_ || scan_pending_;
				});
				if (stop.stop_requested()) return;
				semantic_busy_ = true;
				pending.swap(pending_); closes.swap(closes_); refreshes.swap(refreshes_);
				configure = configuration_pending_; configuration_pending_ = false;
				configuration = configuration_;
				scan = scan_pending_; scan_pending_ = false;
			}
			if (scan) {
				auto current = scan_disk_stamps(root_value, stop);
				++disk_scans_;
				for (const auto &[uri, stamp] : current) {
					auto old = disk_stamps.find(uri);
					if (old == disk_stamps.end() || old->second != stamp) refreshes.insert(uri);
				}
				for (const auto &[uri, stamp] : disk_stamps)
					if (!current.contains(uri)) refreshes.insert(uri);
				disk_stamps = std::move(current);
			}
			// Record targeted writes before indexing, so a later census does not redo their work.
			for (const auto &uri : refreshes) {
				if (auto path = path_for_file_uri(uri)) {
					if (auto stamp = disk_stamp(*path); stamp && stamp->exists) disk_stamps[uri] = *stamp;
					else disk_stamps.erase(uri);
				}
			}
			std::vector<std::string> affected;
			{
				std::lock_guard semantic_lock(semantic_mutex_);
				if (configure) workspace_->set_completion_config(configuration);
				for (const auto &uri : closes) {
					auto before = workspace_->affected_documents({uri});
					affected.insert(affected.end(), before.begin(), before.end());
					workspace_->close_document(uri);
					affected.push_back(uri);
				}
				if (!refreshes.empty()) {
					std::vector<std::string> paths(refreshes.begin(), refreshes.end());
					auto before = workspace_->affected_documents(paths);
					affected.insert(affected.end(), before.begin(), before.end());
					workspace_->refresh_files(paths);
					++refresh_batches_;
					affected.insert(affected.end(), paths.begin(), paths.end());
				}
				for (const auto &[uri, snapshot] : pending) {
					UpdateImpact impact;
					if (workspace_->update_document(*snapshot, nullptr, &impact))
						affected.insert(affected.end(), impact.affected_documents.begin(), impact.affected_documents.end());
				}
				auto after = workspace_->affected_documents(affected);
				affected.insert(affected.end(), after.begin(), after.end());
				semantic_busy_ = false;
			}
			if (!stop.stop_requested()) call_deferred("_finish_update", generation, packed_paths(affected));
		}
	});
	return OK;
}

bool GDScriptLanguageService::is_ready() const { return ready_.load(); }

void GDScriptLanguageService::_finish_open(int64_t generation, const String &error) {
	if (generation != generation_) return;
	ready_.store(error.is_empty());
	if (error.is_empty()) emit_signal("workspace_ready");
	else emit_signal("workspace_error", error);
}

void GDScriptLanguageService::_finish_update(int64_t generation, const PackedStringArray &paths) {
	if (generation != generation_) return;
	emit_signal("index_updated", paths);
	emit_signal("diagnostics_updated", paths);
}

void GDScriptLanguageService::update_document(const String &uri, const String &text, int64_t version) {
	if (project_root_.empty()) project_root_ = to_std(ProjectSettings::get_singleton()->globalize_path("res://"));
	auto target = target_uri(uri);
	auto &doc = documents_[target];
	if (doc.is_null()) doc.instantiate();
	auto previous = doc->snapshot();
	if (previous && version <= previous->version()) return;
	auto source = to_std(text);
	auto path = to_std(uri);
	if (auto file = path_for_file_uri(target)) path = "res://" + file->lexically_relative(project_root_).generic_string();
	auto snapshot = previous
		? std::make_shared<Document>(target, path, std::move(source), version, *previous, Document::Analysis::Deferred)
		: std::make_shared<Document>(target, path, std::move(source), version, Document::Analysis::Deferred);
	doc->set_snapshot(snapshot);
	// Session/built-in sources support syntax even when no workspace file exists.
	if (!path_for_file_uri(target) || uri.contains("::")) return;
	{
		std::lock_guard lock(queue_mutex_);
		pending_[target] = std::move(snapshot);
		closes_.erase(target);
	}
	queue_changed_.notify_all();
}

void GDScriptLanguageService::close_document(const String &uri) {
	auto target = target_uri(uri);
	if (auto found = documents_.find(target); found != documents_.end()) found->second->clear_brackets();
	documents_.erase(target);
	{
		std::lock_guard lock(queue_mutex_);
		pending_.erase(target);
		closes_.insert(target);
	}
	queue_changed_.notify_all();
}

void GDScriptLanguageService::invalidate_files(const PackedStringArray &paths) {
	for (const auto &path : paths) readonly_stamps_.erase(target_uri(path));
}

void GDScriptLanguageService::request_disk_scan() { refresh_files({}, true); }

Dictionary GDScriptLanguageService::get_refresh_stats() const {
	Dictionary result;
	result["disk_reads"] = static_cast<int64_t>(disk_reads_);
	result["disk_scans"] = static_cast<int64_t>(disk_scans_.load());
	result["refresh_batches"] = static_cast<int64_t>(refresh_batches_.load());
	return result;
}

void GDScriptLanguageService::refresh_files(const PackedStringArray &paths, bool scan) {
	invalidate_files(paths);
	std::lock_guard lock(queue_mutex_);
	for (const auto &path : paths) {
		auto target = target_uri(path);
		// Disk notifications must never replace an open editor buffer.
		if (!documents_.contains(target)) refreshes_.insert(target);
	}
	scan_pending_ |= scan;
	queue_changed_.notify_all();
}

Dictionary GDScriptLanguageService::completion(const String &uri, int line, int utf16_column) const {
	return completion_ex(uri, line, utf16_column);
}

Dictionary GDScriptLanguageService::completion_ex(const String &uri, int line, int utf16_column,
		const Dictionary &options) const {
	std::unique_lock lock(semantic_mutex_, std::try_to_lock);
	if (!lock.owns_lock() || !current(uri)) {
		CompletionResult pending;
		pending.is_incomplete = true;
		return completion_dict(pending);
	}
	auto profile = CompletionProfile::Full;
	if (options.has("profile") && String(options["profile"]) == "helpers") profile = CompletionProfile::Helpers;
	return completion_dict(workspace_->completion_result(target_uri(uri),
		{static_cast<uint32_t>(line), static_cast<uint32_t>(utf16_column)}, profile));
}

void GDScriptLanguageService::set_configuration(const Dictionary &configuration) {
	Dictionary root = configuration;
	if (root.has("gdscriptLsp") && Variant(root["gdscriptLsp"]).get_type() == Variant::DICTIONARY) {
		root = root["gdscriptLsp"];
	}
	if (!root.has("completion") || Variant(root["completion"]).get_type() != Variant::DICTIONARY) return;
	Dictionary completion = root["completion"];
	std::lock_guard lock(queue_mutex_);
	auto config = configuration_;
	auto boolean = [&](const char *name, bool &target) {
		if (completion.has(name) && Variant(completion[name]).get_type() == Variant::BOOL) target = completion[name];
	};
	boolean("enums", config.enums);
	boolean("extendedTypeHints", config.extended_type_hints);
	boolean("constructors", config.constructors);
	boolean("hidePrivate", config.hide_private);
	if (completion.has("memberStrings")) {
		Variant member_value = completion["memberStrings"];
		if (member_value.get_type() == Variant::BOOL) config.member_strings = member_value;
		else if (member_value.get_type() == Variant::DICTIONARY) {
			Dictionary member_strings = member_value;
			auto member_boolean = [&](const char *name, bool &target) {
				if (member_strings.has(name) && Variant(member_strings[name]).get_type() == Variant::BOOL) target = member_strings[name];
			};
			member_boolean("enabled", config.member_strings);
			member_boolean("preferStringName", config.member_strings_prefer_string_name);
			member_boolean("includePrivate", config.member_strings_include_private);
		}
	}
	configuration_ = config;
	configuration_pending_ = true;
	queue_changed_.notify_all();
}

Dictionary GDScriptLanguageService::hover(const String &uri, int line, int utf16_column) const {
	Dictionary result;
	std::unique_lock lock(semantic_mutex_, std::try_to_lock);
	if (!lock.owns_lock() || !current(uri)) return result;
	auto value = workspace_->hover(target_uri(uri), {static_cast<uint32_t>(line), static_cast<uint32_t>(utf16_column)});
	if (!value) return result;
	Dictionary contents;
	contents["kind"] = "markdown";
	contents["value"] = to_godot(value->markdown);
	result["contents"] = contents;
	result["range"] = range_dict(value->range);
	return result;
}

Array GDScriptLanguageService::definition(const String &uri, int line, int utf16_column) const {
	Array result;
	std::unique_lock lock(semantic_mutex_, std::try_to_lock);
	if (!lock.owns_lock() || !current(uri)) return result;
	for (const auto &location : workspace_->definition(target_uri(uri),
				{static_cast<uint32_t>(line), static_cast<uint32_t>(utf16_column)})) {
		Dictionary value;
		value["uri"] = to_godot(location.uri);
		value["range"] = range_dict(location.range);
		result.push_back(value);
	}
	return result;
}

Array GDScriptLanguageService::document_symbols(const String &uri) const {
	Array result;
	std::unique_lock lock(semantic_mutex_, std::try_to_lock);
	if (!lock.owns_lock() || !current(uri)) return result;
	for (const auto &symbol : workspace_->document_outline(target_uri(uri)).symbols) {
		result.push_back(outline_symbol_dict(symbol));
	}
	return result;
}

Array GDScriptLanguageService::diagnostics(const String &uri) const {
	Array result;
	std::unique_lock lock(semantic_mutex_, std::try_to_lock);
	if (!lock.owns_lock() || !current(uri)) return result;
	for (const auto &diagnostic : workspace_->diagnostics(target_uri(uri))) result.push_back(diagnostic_dict(diagnostic));
	return result;
}

Dictionary GDScriptLanguageService::resolve_type(const String &uri, int line, int utf16_column,
		const String &expression) const {
	std::unique_lock lock(semantic_mutex_, std::try_to_lock);
	if (!lock.owns_lock() || !current(uri)) return type_dict(ResolvedType::unknown("indexing"));
	return type_dict(workspace_->resolve_type(target_uri(uri),
		{static_cast<uint32_t>(line), static_cast<uint32_t>(utf16_column)}, to_std(expression)));
}

Dictionary GDScriptLanguageService::resolve_expression(const String &uri, int line, int utf16_column,
		const String &expression) const {
	std::unique_lock lock(semantic_mutex_, std::try_to_lock);
	if (!lock.owns_lock() || !current(uri)) return expression_dict({ResolvedType::unknown("indexing"), std::nullopt, {}});
	return expression_dict(workspace_->resolve_expression(target_uri(uri),
		{static_cast<uint32_t>(line), static_cast<uint32_t>(utf16_column)}, to_std(expression)));
}

} // namespace gdscript_lsp
