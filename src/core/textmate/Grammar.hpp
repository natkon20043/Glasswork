#pragma once

#include "Regex.hpp"

#include <nlohmann/json_fwd.hpp>

#include <deque>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace gw::tm {

class Grammar;
struct Rule;

/// A named set of rules (a grammar's or a rule's `repository`). Nested repositories fall
/// back to their parent when resolving `#name` includes.
struct Repository {
    std::map<std::string, Rule*> entries;
    const Repository* parent = nullptr;

    Rule* find(const std::string& name) const;
};

/// One TextMate rule. The kind follows from which keys the JSON rule had.
struct Rule {
    enum class Kind {
        Match,       // "match": a single regex
        BeginEnd,    // "begin"/"end": a region, possibly spanning lines
        BeginWhile,  // "begin"/"while": a region that continues while each line matches
        Include,     // "include": a reference to other rules
        Group,       // only "patterns": a container
    };

    Kind kind = Kind::Group;
    Grammar* grammar = nullptr;
    const Repository* repository = nullptr;  // where `#name` includes are looked up

    std::string name;
    std::string contentName;
    std::shared_ptr<Regex> match;  // "match", or "begin" for regions
    std::string endSource;         // may hold back-references (\1) filled in per match
    bool endHasBackReferences = false;
    std::shared_ptr<Regex> end;    // compiled end when it has no back-references
    std::shared_ptr<Regex> whilePattern;
    bool applyEndPatternLast = false;

    std::map<int, Rule*> captures;       // for "match"
    std::map<int, Rule*> beginCaptures;  // "beginCaptures", else "captures"
    std::map<int, Rule*> endCaptures;    // "endCaptures", else "captures"
    std::map<int, Rule*> whileCaptures;

    std::vector<Rule*> patterns;

    std::string include;       // for Include rules
    Rule* resolved = nullptr;  // cached target of a non-$base include
};

/// Looks up grammars by scope name (e.g. "source.cpp"), for includes between grammars.
using GrammarLookup = std::function<Grammar*(const std::string& scopeName)>;

/// A parsed TextMate grammar (JSON format, as shipped in VS Code extensions).
class Grammar {
public:
    static std::unique_ptr<Grammar> load(const std::filesystem::path& path, GrammarLookup lookup,
                                         std::string* error = nullptr);
    static std::unique_ptr<Grammar> parse(const std::string& json, GrammarLookup lookup,
                                          std::string* error = nullptr);

    const std::string& scopeName() const { return scopeName_; }
    Rule* root() const { return root_; }

    /// Resolves an Include rule to the rule it names. `base` is the grammar whose document
    /// is being highlighted (for `$base`).
    Rule* resolve(Rule* include, Grammar* base);
    /// Other grammars, for `source.x` and `source.x#name` includes.
    Grammar* grammarFor(const std::string& scopeName) const { return lookup_ ? lookup_(scopeName) : nullptr; }
    Rule* repositoryRule(const std::string& name) const { return repository_.find(name); }

    /// The rules that can start a match inside `container`, with includes and groups
    /// flattened, in priority order. Cached per container and base grammar.
    const std::vector<Rule*>& candidates(Rule* container, Grammar* base);

private:
    Grammar() = default;
    Rule* parseRule(const nlohmann::json& json, const Repository* repository);
    std::map<int, Rule*> parseCaptures(const nlohmann::json& json, const Repository* repository);
    void parseRepository(const nlohmann::json& json, Repository& into);
    void flatten(Rule* container, Grammar* base, std::vector<Rule*>& out, std::vector<Rule*>& visiting);

    std::string scopeName_;
    Rule* root_ = nullptr;
    Repository repository_;
    std::deque<Rule> rules_;                // stable addresses
    std::deque<Repository> repositories_;  // rule-level repositories
    std::map<std::pair<Rule*, Grammar*>, std::vector<Rule*>> candidateCache_;
    GrammarLookup lookup_;
};

}  // namespace gw::tm
