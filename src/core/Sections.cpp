#include "Sections.hpp"

#include <optional>
#include <string_view>

namespace gw {

namespace {

std::string_view trimmed(std::string_view text) {
    size_t start = 0;
    while (start < text.size() && (text[start] == ' ' || text[start] == '\t')) {
        ++start;
    }
    size_t end = text.size();
    while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\t' || text[end - 1] == '\r')) {
        --end;
    }
    return text.substr(start, end - start);
}

bool consume(std::string_view& text, std::string_view prefix) {
    if (text.substr(0, prefix.size()) != prefix) {
        return false;
    }
    text.remove_prefix(prefix.size());
    return true;
}

/// Removes a closing block-comment marker like "*/" or "-->" from the end.
std::string_view withoutCommentEnd(std::string_view text) {
    for (std::string_view ending : {std::string_view("*/"), std::string_view("-->")}) {
        if (text.size() >= ending.size() && text.substr(text.size() - ending.size()) == ending) {
            text.remove_suffix(ending.size());
            break;
        }
    }
    return trimmed(text);
}

/// Turns "- Title" into a divider section called "Title"; "Title" into a plain one.
Section markSection(size_t line, std::string_view rest) {
    Section section;
    section.line = line;
    section.kind = Section::Kind::Mark;
    rest = withoutCommentEnd(trimmed(rest));
    if (consume(rest, "-")) {
        section.divider = true;
        rest = trimmed(rest);
    }
    section.title = std::string(rest);
    return section;
}

std::optional<Section> sectionForLine(size_t line, std::string_view text) {
    text = trimmed(text);

    // C and Objective-C: #pragma mark - Title
    if (consume(text, "#pragma mark")) {
        return markSection(line, text);
    }

    // Otherwise it must start with a comment marker.
    bool isComment = false;
    for (std::string_view marker : {"//", "/*", "<!--", "--", "#", ";"}) {
        if (consume(text, marker)) {
            isComment = true;
            break;
        }
    }
    if (!isComment) {
        return std::nullopt;
    }
    while (!text.empty() && (text.front() == '/' || text.front() == '*' || text.front() == ' ' || text.front() == '\t')) {
        text.remove_prefix(1);
    }

    if (consume(text, "MARK:")) {
        return markSection(line, text);
    }
    if (consume(text, "TODO:")) {
        Section section;
        section.line = line;
        section.kind = Section::Kind::Todo;
        section.title = std::string(withoutCommentEnd(trimmed(text)));
        return section;
    }
    if (consume(text, "FIXME:")) {
        Section section;
        section.line = line;
        section.kind = Section::Kind::Fixme;
        section.title = std::string(withoutCommentEnd(trimmed(text)));
        return section;
    }
    return std::nullopt;
}

}  // namespace

std::vector<Section> findSections(const TextBuffer& buffer) {
    std::vector<Section> sections;
    for (size_t line = 0; line < buffer.lineCount(); ++line) {
        std::string_view text = buffer.line(line);
        // Cheap early exit: every form we recognise contains one of these letters.
        if (text.find_first_of("MTFp") == std::string::npos) {
            continue;
        }
        std::optional<Section> section = sectionForLine(line, text);
        if (section) {
            sections.push_back(*section);
        }
    }
    return sections;
}

long sectionContaining(const std::vector<Section>& sections, size_t line) {
    long found = -1;
    for (size_t index = 0; index < sections.size(); ++index) {
        if (sections[index].line > line) {
            break;
        }
        if (sections[index].kind == Section::Kind::Mark) {
            found = static_cast<long>(index);
        }
    }
    return found;
}

}  // namespace gw
