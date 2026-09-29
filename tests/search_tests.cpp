// Tests for the text search used by "Find in Files" and the find bar.

#include "TestHarness.hpp"

#include "ProjectSearch.hpp"

#include <atomic>
#include <filesystem>
#include <fstream>
#include <unistd.h>

namespace {

using gw::search::Matcher;
using gw::search::Query;

Query queryFor(const std::string& pattern, bool caseSensitive = false, bool wholeWord = false, bool regex = false) {
    Query query;
    query.pattern = pattern;
    query.caseSensitive = caseSensitive;
    query.wholeWord = wholeWord;
    query.useRegex = regex;
    return query;
}

/// Every match in a line as "start:length" pairs.
std::vector<std::pair<size_t, size_t>> matchesIn(const Matcher& matcher, std::string_view line) {
    std::vector<std::pair<size_t, size_t>> matches;
    matcher.forEachInLine(line, [&matches](size_t start, size_t length) { matches.emplace_back(start, length); });
    return matches;
}

std::vector<size_t> linesMatching(const Matcher& matcher, std::string_view text) {
    std::vector<size_t> lines;
    matcher.forEachMatchingLine(text, [&lines](size_t line, size_t, size_t) {
        lines.push_back(line);
        return true;
    });
    return lines;
}

std::string makeFolder(const std::string& label) {
    std::filesystem::path path = std::filesystem::temp_directory_path() / ("glasswork-" + label + "-" + std::to_string(getpid()));
    std::filesystem::remove_all(path);
    std::filesystem::create_directories(path);
    return std::filesystem::canonical(path).string();
}

void writeFile(const std::string& path, const std::string& text) {
    std::filesystem::create_directories(std::filesystem::path(path).parent_path());
    std::ofstream file(path, std::ios::binary);
    file << text;
}

TEST(literalSearchRespectsCase) {
    Matcher sensitive(queryFor("Foo", true));
    CHECK(sensitive.valid());
    CHECK_EQ(matchesIn(sensitive, "Foo foo FOO Foo").size(), size_t(2));

    Matcher insensitive(queryFor("Foo", false));
    auto matches = matchesIn(insensitive, "Foo foo FOO xfoox");
    CHECK_EQ(matches.size(), size_t(4));
    CHECK_EQ(matches[3].first, size_t(13));
}

TEST(literalSearchFindsMatchesAtEdgesAndOverlaps) {
    Matcher matcher(queryFor("aa", true));
    auto matches = matchesIn(matcher, "aaaa");
    CHECK_EQ(matches.size(), size_t(2));  // non-overlapping: 0 and 2
    CHECK_EQ(matches[1].first, size_t(2));
    CHECK_EQ(matchesIn(matcher, "aa").size(), size_t(1));
    CHECK_EQ(matchesIn(matcher, "a").size(), size_t(0));
    CHECK_EQ(matchesIn(matcher, "").size(), size_t(0));

    Matcher single(queryFor("x", true));
    CHECK_EQ(matchesIn(single, "x.x.x").size(), size_t(3));
}

TEST(wholeWordSearchIgnoresPartsOfWords) {
    Matcher matcher(queryFor("cat", false, true));
    auto matches = matchesIn(matcher, "cat concat cat_x cat. (cat) Cat");
    // "cat", "cat." , "(cat)" and "Cat"
    CHECK_EQ(matches.size(), size_t(4));
}

TEST(regexSearchAndGroups) {
    Matcher matcher(queryFor("(\\w+)@(\\w+)\\.com", true, false, true));
    CHECK(matcher.valid());
    std::string line = "mail ann@example.com or bob@test.com now";
    auto matches = matchesIn(matcher, line);
    CHECK_EQ(matches.size(), size_t(2));
    CHECK_EQ(matcher.expand(line, matches[0].first, matches[0].second, "$2:$1"), std::string("example:ann"));
    CHECK_EQ(matcher.expand(line, matches[1].first, matches[1].second, "[$&]"), std::string("[bob@test.com]"));
    CHECK_EQ(matcher.expand(line, matches[1].first, matches[1].second, "$$1"), std::string("$1"));
}

TEST(badRegexReportsAnErrorInsteadOfCrashing) {
    Matcher matcher(queryFor("(unclosed", true, false, true));
    CHECK(!matcher.valid());
    CHECK(!matcher.error().empty());
    CHECK(matchesIn(matcher, "(unclosed").empty());

    Matcher empty(queryFor(""));
    CHECK(!empty.valid());
}

TEST(regexCaseAndWholeWordOptionsApply) {
    Matcher matcher(queryFor("foo.", false, true, true));
    CHECK_EQ(matchesIn(matcher, "FOOD foods food").size(), size_t(2));
}

TEST(matchingLinesAreNumberedFromZero) {
    Matcher matcher(queryFor("needle", true));
    std::string text = "one\nneedle here\nthree\n\nneedle needle\nlast needle";
    std::vector<size_t> lines = linesMatching(matcher, text);
    CHECK_EQ(lines.size(), size_t(3));
    CHECK_EQ(lines[0], size_t(1));
    CHECK_EQ(lines[1], size_t(4));
    CHECK_EQ(lines[2], size_t(5));

    // The reported extent is the whole line.
    matcher.forEachMatchingLine(text, [&](size_t line, size_t start, size_t length) {
        if (line == 1) {
            CHECK_EQ(std::string(text.substr(start, length)), std::string("needle here"));
        }
        return true;
    });

    Matcher regex(queryFor("^t", true, false, true));
    std::vector<size_t> starts = linesMatching(regex, text);
    CHECK_EQ(starts.size(), size_t(1));  // only "three"
    CHECK_EQ(starts[0], size_t(2));
}

TEST(searchCanStopEarly) {
    Matcher matcher(queryFor("a", true));
    size_t seen = 0;
    matcher.forEachMatchingLine("a\na\na\na", [&seen](size_t, size_t, size_t) {
        ++seen;
        return seen < 2;
    });
    CHECK_EQ(seen, size_t(2));
}

TEST(replaceAllHandlesLiteralsRegexAndLineBreaks) {
    size_t count = 0;
    Matcher literal(queryFor("old", true));
    CHECK_EQ(literal.replaceAll("old and old\nnot bold\nold", "new", &count), std::string("new and new\nnot bnew\nnew"));
    CHECK_EQ(count, size_t(4));

    Matcher whole(queryFor("old", true, true));
    CHECK_EQ(whole.replaceAll("old bold old_", "X", &count), std::string("X bold old_"));
    CHECK_EQ(count, size_t(1));

    Matcher regex(queryFor("(\\d+)-(\\d+)", true, false, true));
    CHECK_EQ(regex.replaceAll("10-20 and 3-4\nend 5-6", "$2..$1", &count), std::string("20..10 and 4..3\nend 6..5"));
    CHECK_EQ(count, size_t(3));

    CHECK_EQ(literal.replaceAll("nothing here", "x", &count), std::string("nothing here"));
    CHECK_EQ(count, size_t(0));
    CHECK_EQ(literal.replaceAll("old\n", "", &count), std::string("\n"));  // deleting is fine, line breaks stay
}

TEST(filtersUseFileNamesFoldersAndWildcards) {
    auto includes = gw::search::splitPatterns("*.cpp, src/");
    auto excludes = gw::search::splitPatterns("build, *.min.js");
    CHECK_EQ(includes.size(), size_t(2));
    CHECK(gw::search::passesFilters("src/a.cpp", includes, excludes));
    CHECK(gw::search::passesFilters("src/deep/b.txt", includes, excludes));
    CHECK(gw::search::passesFilters("tools/c.cpp", includes, excludes));
    CHECK(!gw::search::passesFilters("docs/readme.md", includes, excludes));
    CHECK(!gw::search::passesFilters("src/build/x.cpp", includes, excludes));
    CHECK(!gw::search::passesFilters("build/x.cpp", includes, excludes));
    CHECK(gw::search::passesFilters("anything.txt", {}, {}));
    CHECK(!gw::search::passesFilters("a/b.min.js", {}, excludes));
}

TEST(searchingFilesFindsHitsSkipsBinaryAndHonoursLimits) {
    std::string root = makeFolder("search");
    writeFile(root + "/a.txt", "hello world\nsecond line\nhello again\n");
    writeFile(root + "/sub/b.txt", "nothing\n   indented hello\n");
    writeFile(root + "/sub/deeper/c.md", "Hello in markdown\n");
    writeFile(root + "/binary.bin", std::string("hello\0hello", 11));
    writeFile(root + "/empty.txt", "");
    std::string many;
    for (int index = 0; index < 500; ++index) {
        many += "hello number " + std::to_string(index) + "\n";
    }
    writeFile(root + "/many.txt", many);

    gw::search::SearchOptions options;
    options.root = root;
    options.files = {"a.txt", "sub/b.txt", "sub/deeper/c.md", "binary.bin", "empty.txt", "many.txt", "missing.txt"};
    Matcher matcher(queryFor("hello"));

    std::vector<gw::search::FileResult> results;
    std::atomic<bool> cancel{false};
    gw::search::SearchSummary summary = gw::search::searchFiles(options, matcher, &cancel, [&](gw::search::FileResult&& result) {
        results.push_back(std::move(result));
    });
    std::sort(results.begin(), results.end(), [](const auto& a, const auto& b) { return a.path < b.path; });

    CHECK_EQ(results.size(), size_t(4));  // a.txt, many.txt, sub/b.txt, sub/deeper/c.md
    CHECK_EQ(results[0].path, std::string("a.txt"));
    CHECK_EQ(results[0].hits.size(), size_t(2));
    CHECK_EQ(results[0].hits[0].line, size_t(0));
    CHECK_EQ(results[0].hits[1].line, size_t(2));
    CHECK_EQ(results[0].hits[0].ranges.size(), size_t(1));
    CHECK_EQ(results[0].hits[0].ranges[0].first, uint32_t(0));

    // many.txt: the listing is capped but the count is real.
    CHECK_EQ(results[1].path, std::string("many.txt"));
    CHECK_EQ(results[1].matchCount, size_t(500));
    CHECK_EQ(results[1].hits.size(), size_t(200));
    CHECK(results[1].truncated);

    // Indentation is trimmed from previews, and the match range moves with it.
    CHECK_EQ(results[2].path, std::string("sub/b.txt"));
    CHECK_EQ(results[2].hits[0].text, std::string("indented hello"));
    CHECK_EQ(results[2].hits[0].ranges[0].first, uint32_t(9));
    CHECK_EQ(results[2].hits[0].column, size_t(12));  // column in the original line

    CHECK_EQ(summary.filesWithMatches, size_t(4));
    CHECK(summary.filesSearched >= 5);

    // Filters narrow the list.
    options.include = "*.md";
    results.clear();
    gw::search::searchFiles(options, matcher, &cancel, [&](gw::search::FileResult&& result) { results.push_back(std::move(result)); });
    CHECK_EQ(results.size(), size_t(1));

    // Cancelling before starting searches nothing.
    options.include = "";
    cancel.store(true);
    results.clear();
    gw::search::searchFiles(options, matcher, &cancel, [&](gw::search::FileResult&& result) { results.push_back(std::move(result)); });
    CHECK(results.empty());

    std::filesystem::remove_all(root);
}

TEST(longLinesAreCutAroundTheMatch) {
    std::string root = makeFolder("longline");
    std::string line(600, 'x');
    line += " needle ";
    line += std::string(600, 'y');
    writeFile(root + "/long.txt", line + "\n");

    gw::search::SearchOptions options;
    options.root = root;
    options.files = {"long.txt"};
    Matcher matcher(queryFor("needle"));
    std::vector<gw::search::FileResult> results;
    gw::search::searchFiles(options, matcher, nullptr, [&](gw::search::FileResult&& result) { results.push_back(std::move(result)); });
    CHECK_EQ(results.size(), size_t(1));
    const gw::search::LineHit& hit = results[0].hits[0];
    CHECK(hit.text.size() < 400);
    CHECK_EQ(hit.text.substr(hit.ranges[0].first, hit.ranges[0].second), std::string("needle"));
    CHECK_EQ(hit.column, size_t(600 + 1));
    std::filesystem::remove_all(root);
}

TEST(literalSearchIsFastOnLargeText) {
    // 40 MB of source-like text with a rare word near the end.
    std::string text;
    text.reserve(45 * 1024 * 1024);
    while (text.size() < 40 * 1024 * 1024) {
        text += "    for (int index = 0; index < count; ++index) { total += values[index] * scale; }\n";
    }
    text += "the rare_identifier_here lives on the last line\n";

    for (bool caseSensitive : {true, false}) {
        Matcher matcher(queryFor("rare_identifier_here", caseSensitive));
        auto begin = std::chrono::steady_clock::now();
        size_t hits = 0;
        matcher.forEachMatchingLine(text, [&hits](size_t, size_t, size_t) {
            ++hits;
            return true;
        });
        double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
        double gigabytesPerSecond = static_cast<double>(text.size()) / 1e9 / seconds;
        std::printf("    %s literal search: %.2f GB/s\n", caseSensitive ? "case-sensitive" : "case-insensitive", gigabytesPerSecond);
        CHECK_EQ(hits, size_t(1));
        CHECK(seconds < 1.0);
    }
}

}  // namespace

int main() {
    return harness::runAllTests();
}
