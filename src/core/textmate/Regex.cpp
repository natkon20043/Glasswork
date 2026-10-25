#include "Regex.hpp"

#include <oniguruma.h>

#include <atomic>
#include <mutex>
#include <unordered_map>

namespace gw::tm {

namespace {

std::atomic<bool> gFirstByteSkipping{true};

/// Each thread keeps one match buffer for all its searches instead of allocating one each time.
OnigRegion* threadRegion() {
    struct Holder {
        OnigRegion* region = onig_region_new();
        ~Holder() { onig_region_free(region, 1); }
    };
    static thread_local Holder holder;
    return holder.region;
}

void initializeOnce() {
    static std::once_flag flag;
    std::call_once(flag, [] {
        OnigEncoding encodings[] = {ONIG_ENCODING_UTF8};
        onig_initialize(encodings, 1);
    });
}

}  // namespace

Regex::Regex(const std::string& source) : source_(source) {
    initializeOnce();
    anchored_ = source.find("\\G") != std::string::npos;
    auto* begin = reinterpret_cast<const OnigUChar*>(source.data());
    OnigErrorInfo error;
    regex_t* compiled = nullptr;
    int result = onig_new(&compiled, begin, begin + source.size(), ONIG_OPTION_CAPTURE_GROUP, ONIG_ENCODING_UTF8,
                          ONIG_SYNTAX_ONIGURUMA, &error);
    if (result == ONIG_NORMAL) {
        regex_ = compiled;
    }

    FirstBytes first = analyzeFirstBytes(source);
    hasFirstBytes_ = first.restricted;
    firstBytes_ = first.bytes;
}

void Regex::setFirstByteSkippingEnabled(bool enabled) {
    gFirstByteSkipping.store(enabled);
}

Regex::~Regex() {
    if (regex_) {
        onig_free(regex_);
    }
}

Match Regex::search(const std::string& text, size_t from) const {
    Match match;
    if (!regex_ || from > text.size()) {
        return match;
    }

    // Skip ahead to the first byte a match could begin with; if there is none, there is no match.
    size_t begin = from;
    if (hasFirstBytes_ && gFirstByteSkipping.load(std::memory_order_relaxed)) {
        while (begin < text.size() && !firstBytes_[static_cast<unsigned char>(text[begin])]) {
            ++begin;
        }
        if (begin >= text.size()) {
            return match;
        }
    }

    auto* start = reinterpret_cast<const OnigUChar*>(text.data());
    auto* end = start + text.size();
    OnigRegion* region = threadRegion();
    int result = onig_search(regex_, start, end, start + begin, end, region, ONIG_OPTION_NONE);
    if (result >= 0) {
        match.found = true;
        match.groups.reserve(static_cast<size_t>(region->num_regs));
        for (int index = 0; index < region->num_regs; ++index) {
            match.groups.emplace_back(region->beg[index], region->end[index]);
        }
    }
    return match;
}

const Regex& Regex::withoutAnchor() const {
    if (!anchored_) {
        return *this;
    }
    static std::mutex mutex;
    std::lock_guard lock(mutex);
    if (!unanchored_) {
        // Replace each real \G escape (not an escaped backslash followed by G) with a
        // character that never occurs in source text.
        std::string replaced;
        for (size_t index = 0; index < source_.size(); ++index) {
            if (source_[index] == '\\' && index + 1 < source_.size()) {
                if (source_[index + 1] == 'G') {
                    replaced += "\\x{FFFF}";
                } else {
                    replaced += source_[index];
                    replaced += source_[index + 1];
                }
                ++index;
                continue;
            }
            replaced += source_[index];
        }
        unanchored_ = get(replaced);
    }
    return *unanchored_;
}

std::shared_ptr<Regex> Regex::get(const std::string& source) {
    static std::mutex mutex;
    static std::unordered_map<std::string, std::shared_ptr<Regex>> cache;
    std::lock_guard lock(mutex);
    if (auto found = cache.find(source); found != cache.end()) {
        return found->second;
    }
    // End patterns with back-references compile one variant per match; keep the cache bounded.
    if (cache.size() > 20000) {
        cache.clear();
    }
    auto regex = std::make_shared<Regex>(source);
    cache.emplace(source, regex);
    return regex;
}

std::string escapeForRegex(const std::string& text) {
    static const std::string special = "\\|()[]{}^$*+?.-/#";
    std::string escaped;
    escaped.reserve(text.size() * 2);
    for (char character : text) {
        if (special.find(character) != std::string::npos) {
            escaped += '\\';
        }
        escaped += character;
    }
    return escaped;
}

}  // namespace gw::tm
