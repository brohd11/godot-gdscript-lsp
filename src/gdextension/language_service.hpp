#pragma once

#include "core/workspace.hpp"
#include "structural_document.hpp"
#include <condition_variable>
#include <unordered_map>
#include <unordered_set>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <atomic>
#include <memory>
#include <thread>

namespace gdscript_lsp {

class GDScriptLanguageService : public godot::RefCounted {
	GDCLASS(GDScriptLanguageService, godot::RefCounted)

public:
	GDScriptLanguageService();
	~GDScriptLanguageService() override;

	// Starts asynchronous indexing; completion emits workspace_ready or workspace_error.
	godot::Error open_workspace(const godot::String &project_root, const godot::Dictionary &options = {});
	// Workspace opening succeeded; subsequent document updates may still be pending.
	bool is_ready() const;
	// Semantic reads can use this revision now; may be false during work/lock contention.
	// Structural document reads do not require either readiness check or a workspace.
	bool is_document_ready(const godot::String &uri) const;
	void update_document(const godot::String &uri, const godot::String &text, int64_t version);
	godot::Ref<godot::GDScriptLSPDocument> document(const godot::String &uri) const;
	void close_document(const godot::String &uri);
	void refresh_files(const godot::PackedStringArray &paths);
	godot::Dictionary completion(const godot::String &uri, int line, int utf16_column) const;
	godot::Dictionary completion_ex(const godot::String &uri, int line, int utf16_column,
		const godot::Dictionary &options = {}) const;
	void set_configuration(const godot::Dictionary &configuration);
	godot::Dictionary hover(const godot::String &uri, int line, int utf16_column) const;
	godot::Array definition(const godot::String &uri, int line, int utf16_column) const;
	godot::Array document_symbols(const godot::String &uri) const;
	godot::Array diagnostics(const godot::String &uri) const;
	godot::Dictionary resolve_type(const godot::String &uri, int line, int utf16_column,
		const godot::String &expression = {}) const;
	godot::Dictionary resolve_expression(const godot::String &uri, int line, int utf16_column,
		const godot::String &expression = {}) const;

	void _finish_open(int64_t generation, const godot::String &error);
	void _finish_update(int64_t generation, const godot::PackedStringArray &paths);

protected:
	static void _bind_methods();

private:
	std::string target_uri(const godot::String &uri) const;
	bool current(const godot::String &uri) const;
	std::filesystem::path project_root_;
	std::unordered_map<std::string, godot::Ref<godot::GDScriptLSPDocument>> documents_;
	mutable std::mutex semantic_mutex_;
	mutable std::mutex queue_mutex_;
	std::condition_variable_any queue_changed_;
	std::unordered_map<std::string, std::shared_ptr<const Document>> pending_;
	std::unordered_set<std::string> closes_, refreshes_;
	CompletionConfig configuration_;
	bool configuration_pending_ = false;
	int64_t generation_ = 0;
	std::unique_ptr<Workspace> workspace_;
	std::jthread index_thread_;
	std::atomic_bool ready_ = false;
	std::atomic_bool semantic_busy_ = false;
};

} // namespace gdscript_lsp
