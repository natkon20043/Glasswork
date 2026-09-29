#include "Grammar.hpp"

#include "../Jsonc.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <fstream>
#include <sstream>

namespace gw::tm {

using nlohmann::json;

Rule* Repository::find(const std::string& name) const {
    for (const Repository* repository = this; repository; repository = repository->parent) {
        if (auto found = repository->entries.find(name); found != repository->entries.end()) return found->second;
    }
    return nullptr;
}

std::unique_ptr<Grammar> Grammar::load(const std::filesystem::path& path, GrammarLookup lookup, std::string* error) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        if (error) *error = "Couldn't read grammar " + path.string();
        return nullptr;
    }
    std::ostringstream contents;
    contents << file.rdbuf();
    return parse(contents.str(), std::move(lookup), error);
}

std::unique_ptr<Grammar> Grammar::parse(const std::string& text, GrammarLookup lookup, std::string* error) {
    json document = gw::parseJsonc(text);
    if (document.is_discarded() || !document.is_object()) {
        if (error) *error = "Grammar isn't valid JSON (only JSON grammars are supported).";
        return nullptr;
    }
    std::unique_ptr<Grammar> grammar(new Grammar());
    grammar->lookup_ = std::move(lookup);
    grammar->scopeName_ = document.value("scopeName", "");
    if (document.contains("repository")) grammar->parseRepository(document["repository"], grammar->repository_);

    Rule& root = grammar->rules_.emplace_back();
    root.kind = Rule::Kind::Group;
    root.grammar = grammar.get();
    root.repository = &grammar->repository_;
    root.name = grammar->scopeName_;
    if (document.contains("patterns") && document["patterns"].is_array()) {
        for (const auto& pattern : document["patterns"]) {
            if (Rule* rule = grammar->parseRule(pattern, &grammar->repository_)) root.patterns.push_back(rule);
        }
    }
    grammar->root_ = &root;
    return grammar;
}

void Grammar::parseRepository(const json& object, Repository& into) {
    if (!object.is_object()) return;
    // Register every entry before parsing bodies isn't needed: includes resolve lazily.
    for (const auto& [key, value] : object.items()) {
        if (Rule* rule = parseRule(value, &into)) into.entries[key] = rule;
    }
}

Rule* Grammar::parseRule(const json& object, const Repository* repository) {
    if (!object.is_object()) return nullptr;
    Rule& rule = rules_.emplace_back();
    rule.grammar = this;
    rule.repository = repository;

    // A rule may carry its own repository, visible to its patterns.
    if (object.contains("repository") && object["repository"].is_object()) {
        Repository& nested = repositories_.emplace_back();
        nested.parent = repository;
        parseRepository(object["repository"], nested);
        rule.repository = &nested;
    }

    auto text = [&](const char* key) -> std::string {
        auto found = object.find(key);
        return found != object.end() && found->is_string() ? found->get<std::string>() : std::string();
    };
    rule.name = text("name");
    rule.contentName = text("contentName");
    rule.applyEndPatternLast = object.contains("applyEndPatternLast") &&
                               (object["applyEndPatternLast"].is_boolean() ? object["applyEndPatternLast"].get<bool>()
                                                                          : object["applyEndPatternLast"] == 1);

    if (object.contains("include")) {
        rule.kind = Rule::Kind::Include;
        rule.include = text("include");
        return &rule;
    }

    if (object.contains("patterns") && object["patterns"].is_array()) {
        for (const auto& pattern : object["patterns"]) {
            if (Rule* child = parseRule(pattern, rule.repository)) rule.patterns.push_back(child);
        }
    }

    std::map<int, Rule*> shared;
    if (object.contains("captures")) shared = parseCaptures(object["captures"], rule.repository);

    if (object.contains("match")) {
        rule.kind = Rule::Kind::Match;
        rule.match = Regex::get(text("match"));
        rule.captures = shared;
    } else if (object.contains("begin")) {
        rule.match = Regex::get(text("begin"));
        rule.beginCaptures = object.contains("beginCaptures") ? parseCaptures(object["beginCaptures"], rule.repository) : shared;
        if (object.contains("while")) {
            rule.kind = Rule::Kind::BeginWhile;
            rule.whilePattern = Regex::get(text("while"));
            rule.whileCaptures = object.contains("whileCaptures") ? parseCaptures(object["whileCaptures"], rule.repository) : shared;
        } else {
            rule.kind = Rule::Kind::BeginEnd;
            // A region with no end runs to the end of the document.
            rule.endSource = object.contains("end") ? text("end") : std::string("\\uFFFF(?!x)x");
            rule.endCaptures = object.contains("endCaptures") ? parseCaptures(object["endCaptures"], rule.repository) : shared;
            for (size_t index = 0; index + 1 < rule.endSource.size(); ++index) {
                if (rule.endSource[index] == '\\') {
                    if (std::isdigit(static_cast<unsigned char>(rule.endSource[index + 1]))) {
                        rule.endHasBackReferences = true;
                        break;
                    }
                    ++index;  // skip the escaped character
                }
            }
            if (!rule.endHasBackReferences) rule.end = Regex::get(rule.endSource);
        }
    } else {
        rule.kind = Rule::Kind::Group;
    }
    return &rule;
}

std::map<int, Rule*> Grammar::parseCaptures(const json& object, const Repository* repository) {
    std::map<int, Rule*> captures;
    if (object.is_object()) {
        for (const auto& [key, value] : object.items()) {
            char* end = nullptr;
            long index = std::strtol(key.c_str(), &end, 10);
            if (end == key.c_str() || !value.is_object()) continue;
            Rule* rule = parseRule(value, repository);
            if (rule) {
                rule->kind = Rule::Kind::Group;  // a capture is a name plus optional patterns
                captures[static_cast<int>(index)] = rule;
            }
        }
    } else if (object.is_array()) {  // some grammars list captures as an array
        int index = 0;
        for (const auto& value : object) {
            if (Rule* rule = parseRule(value, repository)) {
                rule->kind = Rule::Kind::Group;
                captures[index] = rule;
            }
            ++index;
        }
    }
    return captures;
}

Rule* Grammar::resolve(Rule* include, Grammar* base) {
    const std::string& reference = include->include;
    if (reference == "$base") return base ? base->root() : root_;
    if (include->resolved) return include->resolved;

    Rule* target = nullptr;
    if (reference == "$self") {
        target = root_;
    } else if (!reference.empty() && reference[0] == '#') {
        target = include->repository ? include->repository->find(reference.substr(1)) : nullptr;
    } else {
        auto hash = reference.find('#');
        std::string scope = reference.substr(0, hash);
        Grammar* other = scope == scopeName_ ? this : grammarFor(scope);
        if (other) target = hash == std::string::npos ? other->root() : other->repositoryRule(reference.substr(hash + 1));
    }
    include->resolved = target;
    return target;
}

const std::vector<Rule*>& Grammar::candidates(Rule* container, Grammar* base) {
    auto key = std::make_pair(container, base);
    if (auto found = candidateCache_.find(key); found != candidateCache_.end()) return found->second;
    std::vector<Rule*> out;
    std::vector<Rule*> visiting;
    flatten(container, base, out, visiting);
    return candidateCache_.emplace(key, std::move(out)).first->second;
}

void Grammar::flatten(Rule* container, Grammar* base, std::vector<Rule*>& out, std::vector<Rule*>& visiting) {
    if (std::find(visiting.begin(), visiting.end(), container) != visiting.end()) return;  // include cycle
    visiting.push_back(container);
    for (Rule* pattern : container->patterns) {
        Rule* rule = pattern;
        if (rule->kind == Rule::Kind::Include) {
            rule = rule->grammar->resolve(rule, base);
            if (!rule) continue;
        }
        if (rule->kind == Rule::Kind::Group) {
            rule->grammar->flatten(rule, base, out, visiting);
        } else if (std::find(out.begin(), out.end(), rule) == out.end()) {
            out.push_back(rule);
        }
    }
    visiting.pop_back();
}

}  // namespace gw::tm
