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

/// Scope name (e.g. "source.cpp") -> the grammar, for includes between grammars.
using GrammarLookup = std::function<Grammar*(const std::string& scopeName)>;

/// A named set of rules. Nested repositories fall back to their parent when resolving `#name`.
struct Repository {
    Rule* find(const std::string& name) const;

    std::map<std::string, Rule*> entries;
    const Repository* parent = nullptr;
};

/// One TextMate rule.
struct Rule {
    // JSON keys present on the rule -> kind:
    //   "match" -> Match, "begin"+"end" -> BeginEnd, "begin"+"while" -> BeginWhile,
    //   "include" -> Include, only "patterns" -> Group.
    enum class Kind {
        Match,
        BeginEnd,
        BeginWhile,
        Include,
        Group,
    };

    Kind kind = Kind::Group;
    Grammar* grammar = nullptr;
    /// Where `#name` includes are looked up.
    const Repository* repository = nullptr;

    std::string name;
    std::string contentName;
    /// "match", or "begin" for regions.
    std::shared_ptr<Regex> match;
    /// May hold back-references (\1) filled in per match.
    std::string endSource;
    bool endHasBackReferences = false;
    /// Compiled end when it has no back-references.
    std::shared_ptr<Regex> end;
    std::shared_ptr<Regex> whilePattern;
    bool applyEndPatternLast = false;

    std::map<int, Rule*> captures;
    /// "beginCaptures", else "captures".
    std::map<int, Rule*> beginCaptures;
    /// "endCaptures", else "captures".
    std::map<int, Rule*> endCaptures;
    std::map<int, Rule*> whileCaptures;

    std::vector<Rule*> patterns;

    /// Include rules only.
    std::string include;
    /// Cached target of a non-$base include.
    Rule* resolved = nullptr;
};

/// A parsed TextMate grammar (JSON format, as shipped in VS Code extensions).
class Grammar {
public:
    // ---- Constructors
    static std::unique_ptr<Grammar> load(const std::filesystem::path& path, GrammarLookup lookup,
                                         std::string* error = nullptr);
    static std::unique_ptr<Grammar> parse(const std::string& json, GrammarLookup lookup,
                                          std::string* error = nullptr);

    // ---- Getters
    const std::string& scopeName() const { return scopeName_; }
    Rule* root() const { return root_; }
    Rule* repositoryRule(const std::string& name) const { return repository_.find(name); }
    /// For `source.x` and `source.x#name` includes.
    Grammar* grammarFor(const std::string& scopeName) const { return lookup_ ? lookup_(scopeName) : nullptr; }

    // ---- Rule resolution
    /// `base` is the grammar of the document being highlighted (for `$base`).
    Rule* resolve(Rule* include, Grammar* base);
    /// Rules that can start a match inside `container`, includes and groups flattened, in priority order.
    /// Cached per container and base grammar.
    const std::vector<Rule*>& candidates(Rule* container, Grammar* base);

private:
    // ---- Private functions
    Grammar() = default;
    Rule* parseRule(const nlohmann::json& json, const Repository* repository);
    std::map<int, Rule*> parseCaptures(const nlohmann::json& json, const Repository* repository);
    void parseRepository(const nlohmann::json& json, Repository& into);
    void flatten(Rule* container, Grammar* base, std::vector<Rule*>& out, std::vector<Rule*>& visiting);

    // ---- Private variables
    std::string scopeName_;
    Rule* root_ = nullptr;
    Repository repository_;
    // Deques keep addresses stable.
    std::deque<Rule> rules_;
    std::deque<Repository> repositories_;
    std::map<std::pair<Rule*, Grammar*>, std::vector<Rule*>> candidateCache_;
    GrammarLookup lookup_;
};

}  // namespace gw::tm
