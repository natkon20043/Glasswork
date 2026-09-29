// A tiny test harness shared by the test programs, so the build stays dependency-free.
//
// Usage: write TEST(name) { CHECK(...); } blocks, then `return runAllTests();` in main().

#pragma once

#include <cstdio>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace harness {

inline int& failures() {
    static int count = 0;
    return count;
}

inline int& checks() {
    static int count = 0;
    return count;
}

using TestBody = std::function<void()>;

inline std::vector<std::pair<const char*, TestBody>>& allTests() {
    static std::vector<std::pair<const char*, TestBody>> tests;
    return tests;
}

struct Registration {
    Registration(const char* name, TestBody body) { allTests().emplace_back(name, std::move(body)); }
};

inline int runAllTests() {
    for (const auto& [name, body] : allTests()) {
        int failuresBefore = failures();
        body();
        std::printf("%s %s\n", failures() == failuresBefore ? "ok  " : "FAIL", name);
    }
    std::printf("\n%d checks, %d failed\n", checks(), failures());
    return failures() == 0 ? 0 : 1;
}

}  // namespace harness

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        ++harness::checks();                                                               \
        if (!(condition)) {                                                                \
            ++harness::failures();                                                         \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);             \
        }                                                                                  \
    } while (0)

#define CHECK_EQ(actual, expected)                                                         \
    do {                                                                                   \
        ++harness::checks();                                                               \
        auto actualValue = (actual);                                                       \
        auto expectedValue = (expected);                                                   \
        if (!(actualValue == expectedValue)) {                                             \
            ++harness::failures();                                                         \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #actual);                \
        }                                                                                  \
    } while (0)

#define TEST(name)                                                       \
    void name();                                                         \
    harness::Registration register_##name(#name, name);                  \
    void name()
