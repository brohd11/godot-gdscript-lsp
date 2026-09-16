#pragma once
#include "ts_helpers.h"
#include "gd_keys.h"
#include <godot_cpp/variant/dictionary.hpp>
#include <vector>

namespace godot {

struct ScopedLambda {
    TSNode node;
    TSNode variable;
};

inline void find_scoped_lambdas(TSNode node, std::vector<ScopedLambda> &out) {
    const char *type = ts_node_type(node);
    if (strcmp(type, "class_definition") == 0 || strcmp(type, "function_definition") == 0 ||
        strcmp(type, "constructor_definition") == 0) return;
    if (strcmp(type, "lambda") == 0) {
        TSNode parent = ts_node_parent(node);
        const char *pt = ts_node_type(parent);
        bool assigned = (strcmp(pt, "variable_statement") == 0 ||
                         strcmp(pt, "export_variable_statement") == 0 ||
                         strcmp(pt, "onready_variable_statement") == 0) &&
                        ts_node_eq(ts_field_node(parent, "value"), node);
        out.push_back({node, assigned ? parent : TSNode{}});
        return;
    }
    for (uint32_t i = 0; i < ts_node_named_child_count(node); ++i)
        find_scoped_lambdas(ts_node_named_child(node, i), out);
}

// The collection owns immediate closures; nested bodies are parsed by the callback.
// Reserve assigned names first so generated names never replace real bindings.
template <typename Parse>
Dictionary collect_scope_lambdas(TSNode body, const char *src, uint32_t src_len,
        bool local_scope, bool query, Dictionary &variables, Parse parse,
        bool changed_only = false, bool variables_only = false) {
    const Keys &K = Keys::get();
    std::vector<ScopedLambda> nodes;
    if (!ts_node_is_null(body)) find_scoped_lambdas(body, nodes);
    Dictionary reserved, out;
    auto owner_key = [&](TSNode var) {
        String name = ts_field(var, "name", src, src_len);
        TSPoint pos = ts_node_start_point(var);
        return local_scope ? name + "-" + itos(pos.row) + "-" + itos(pos.column) : name;
    };
    for (const auto &entry : nodes)
        if (!ts_node_is_null(entry.variable)) reserved[owner_key(entry.variable)] = true;
    for (const auto &entry : nodes) {
        TSPoint start = ts_node_start_point(entry.node), end = ts_node_end_point(entry.node);
        String owner = ts_node_is_null(entry.variable) ? String() : owner_key(entry.variable);
        if (changed_only && !ts_node_has_changes(entry.node)) continue;
        if (variables_only && (owner.is_empty() || !variables.has(owner))) continue;
        String name = owner;
        if (name.is_empty()) {
            String base = "inline_lambda_" + itos(start.row) + "_" + itos(start.column);
            name = base;
            for (int suffix = 1; reserved.has(name) || out.has(name); ++suffix)
                name = base + "_" + itos(suffix);
        }
        Dictionary info = parse(entry.node);
        info[K.column_index] = (int)start.column;
        info[K.end_column] = (int)end.column;
        info[K.owner_variable] = owner;
        if (query) info[K.changed] = (bool)ts_node_has_changes(entry.node);
        out[name] = info;
        if (!owner.is_empty()) {
            String key = query && local_scope ? ts_field(entry.variable, "name", src, src_len) : owner;
            if (variables.has(key)) {
                Dictionary var = variables[key];
                TSPoint pos = ts_node_start_point(entry.variable);
                const StringName &line_key = query ? K.line : K.line_index;
                if ((int)var[line_key] == (int)pos.row &&
                    (!var.has(K.column_index) || (int)var[K.column_index] == (int)pos.column))
                    var[K.lambda] = info;
            }
        }
    }
    return out;
}

} // namespace godot
