#pragma once

#include "TextBuffer.hpp"

#include <string>
#include <vector>

namespace gw {

/// A marked place in a file, from comments like Xcode's:
///
///     // MARK: - Networking        (a section with a divider line above it)
///     // MARK: Helpers             (a section without a divider)
///     #pragma mark - Drawing       (the C/Objective-C spelling)
///     // TODO: handle errors
///     // FIXME: this leaks
///
/// Any line-comment style works (//, #, --, ;), as do block comments on one line.
struct Section {
    enum class Kind { Mark, Todo, Fixme };

    size_t line = 0;
    std::string title;
    Kind kind = Kind::Mark;
    /// "MARK: -" and "#pragma mark -": draw a divider line above this section.
    bool divider = false;
};

std::vector<Section> findSections(const TextBuffer& buffer);

/// The section containing `line`: the last MARK at or above it. Returns -1 if none.
long sectionContaining(const std::vector<Section>& sections, size_t line);

}  // namespace gw
