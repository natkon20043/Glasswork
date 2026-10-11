cmake_minimum_required(VERSION 3.28)
project(Glasswork VERSION 1.2.0 LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OSX_DEPLOYMENT_TARGET 26.0)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(FetchContent)

# JSON: extension manifests, grammars and themes.
FetchContent_Declare(json
    URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(json)

# Oniguruma: the regex engine TextMate grammars are written for. Built statically.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TEST OFF CACHE BOOL "" FORCE)
FetchContent_Declare(oniguruma
    GIT_REPOSITORY https://github.com/kkos/oniguruma.git
    GIT_TAG v6.9.10
    GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(oniguruma)

# ---------------------------------------------------------------------------
# Core: plain C++20, no Apple frameworks. Text model, TextMate engine, themes, extensions.
find_package(CURL REQUIRED)

add_library(glasswork_core STATIC
    src/core/LineStore.cpp
    src/core/TextBuffer.cpp
    src/core/Document.cpp
    src/core/CharacterWidth.cpp
    src/core/Wrap.cpp
    src/core/RowMap.cpp
    src/core/Folding.cpp
    src/core/EditorConfig.cpp
    src/core/SemanticTokens.cpp
    src/core/Tasks.cpp
    src/core/Snippet.cpp
    src/core/SnippetLibrary.cpp
    src/core/NavigationHistory.cpp
    src/core/WordSuggestions.cpp
    src/core/TextTransforms.cpp
    src/core/SelectionExpand.cpp
    src/core/Dap.cpp
    src/core/Highlighter.cpp
    src/core/Jsonc.cpp
    src/core/SettingsLookup.cpp
    src/core/textmate/Regex.cpp
    src/core/textmate/FirstBytes.cpp
    src/core/textmate/Grammar.cpp
    src/core/textmate/Tokenizer.cpp
    src/core/Theme.cpp
    src/core/Styling.cpp
    src/core/EditorSettings.cpp
    src/core/Sections.cpp
    src/core/Fuzzy.cpp
    src/core/CssColor.cpp
    src/core/Glob.cpp
    src/core/IconTheme.cpp
    src/core/Keybindings.cpp
    src/core/CompletionRank.cpp
    src/core/LanguageServer.cpp
    src/core/LspServer.cpp
    src/core/ExtensionHost.cpp
    src/core/Process.cpp
    src/core/LineDiff.cpp
    src/core/Git.cpp
    src/core/Markdown.cpp
    src/core/ProjectSearch.cpp
    src/core/Terminal.cpp
    src/core/Pty.cpp
    src/core/ClaudeProtocol.cpp
    src/core/ClaudeSession.cpp
    src/core/Extensions.cpp)
target_include_directories(glasswork_core PUBLIC src/core)
target_link_libraries(glasswork_core PUBLIC nlohmann_json::nlohmann_json onig CURL::libcurl)
target_compile_options(glasswork_core PRIVATE -Wall -Wextra -Wno-unused-parameter)

# ---------------------------------------------------------------------------
# Tests
enable_testing()
add_executable(glasswork_tests tests/core_tests.cpp)
target_link_libraries(glasswork_tests PRIVATE glasswork_core)
add_test(NAME core COMMAND glasswork_tests)
add_executable(glasswork_layout_tests tests/layout_tests.cpp)
target_link_libraries(glasswork_layout_tests PRIVATE glasswork_core)
add_test(NAME layout COMMAND glasswork_layout_tests)
add_executable(glasswork_lsp_server_tests tests/lsp_server_tests.cpp)
target_link_libraries(glasswork_lsp_server_tests PRIVATE glasswork_core)
target_compile_definitions(glasswork_lsp_server_tests PRIVATE TEST_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
add_test(NAME lsp_server COMMAND glasswork_lsp_server_tests)
add_executable(glasswork_dap_tests tests/dap_tests.cpp)
target_link_libraries(glasswork_dap_tests PRIVATE glasswork_core)
target_compile_definitions(glasswork_dap_tests PRIVATE TEST_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
add_test(NAME dap COMMAND glasswork_dap_tests)
add_executable(glasswork_lsp_tests tests/language_server_tests.cpp)
target_link_libraries(glasswork_lsp_tests PRIVATE glasswork_core)
add_test(NAME language_protocol COMMAND glasswork_lsp_tests)
add_executable(glasswork_git_tests tests/git_tests.cpp)
target_link_libraries(glasswork_git_tests PRIVATE glasswork_core)
add_test(NAME git_and_diff COMMAND glasswork_git_tests)
add_executable(glasswork_markdown_tests tests/markdown_tests.cpp)
target_link_libraries(glasswork_markdown_tests PRIVATE glasswork_core)
add_test(NAME markdown COMMAND glasswork_markdown_tests)
add_executable(glasswork_extension_host_tests tests/extension_host_tests.cpp)
target_link_libraries(glasswork_extension_host_tests PRIVATE glasswork_core)
target_compile_definitions(glasswork_extension_host_tests PRIVATE TEST_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
add_test(NAME extension_host COMMAND glasswork_extension_host_tests)
# The JavaScript half of the host, run against the same sample extension (needs Node.js).
file(GLOB GLASSWORK_NVM_NODES "$ENV{HOME}/.nvm/versions/node/*/bin")
find_program(GLASSWORK_NODE node HINTS ${GLASSWORK_NVM_NODES})
if(GLASSWORK_NODE)
    add_test(NAME extension_host_js COMMAND ${GLASSWORK_NODE} ${CMAKE_SOURCE_DIR}/tests/host/run.js)
endif()
add_executable(glasswork_search_tests tests/search_tests.cpp)
target_link_libraries(glasswork_search_tests PRIVATE glasswork_core)
add_test(NAME search COMMAND glasswork_search_tests)
add_executable(glasswork_terminal_tests tests/terminal_tests.cpp)
target_link_libraries(glasswork_terminal_tests PRIVATE glasswork_core)
add_test(NAME terminal COMMAND glasswork_terminal_tests)
add_executable(glasswork_pty_tests tests/pty_tests.cpp)
target_link_libraries(glasswork_pty_tests PRIVATE glasswork_core)
add_test(NAME pty COMMAND glasswork_pty_tests)
add_executable(glasswork_claude_tests tests/claude_tests.cpp)
target_link_libraries(glasswork_claude_tests PRIVATE glasswork_core)
add_test(NAME claude_protocol COMMAND glasswork_claude_tests)

# Checks the regex shortcut against real grammars (needs the installed language extensions).
add_executable(glasswork_prefilter_tests tests/prefilter_tests.cpp)
target_link_libraries(glasswork_prefilter_tests PRIVATE glasswork_core)

# Speed measurements (see bench/). Build with -DCMAKE_BUILD_TYPE=Release.
add_executable(glasswork_bench bench/bench_core.cpp)
target_link_libraries(glasswork_bench PRIVATE glasswork_core)

# Talks to the real `claude` command (needs it installed and logged in; spends a little).
add_executable(glasswork_claude_live tests/claude_live.cpp)
target_link_libraries(glasswork_claude_live PRIVATE glasswork_core)

# Downloads real extensions from Open VSX and highlights real code (needs network).
add_executable(glasswork_smoke tests/smoke.cpp)
target_link_libraries(glasswork_smoke PRIVATE glasswork_core)

# ---------------------------------------------------------------------------
# The app: an Objective-C++ AppKit shell (for real Liquid Glass) around the C++ core.
set(GLASSWORK_ICON ${CMAKE_SOURCE_DIR}/resources/Glasswork.icns)
set_source_files_properties(${GLASSWORK_ICON} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

add_executable(Glasswork MACOSX_BUNDLE
    ${GLASSWORK_ICON}
    src/app/main.mm
    src/app/AppDelegate.mm
    src/app/MainWindow.mm
    src/app/EditorView.mm
    src/app/FileTree.mm
    src/app/LanguageService.mm
    src/app/CompletionPopup.mm
    src/app/Debugger.mm
    src/app/ShadowedGlass.mm
    src/app/DebugPanel.mm
    src/app/FileIcons.mm
    src/app/ColorInspector.mm
    src/app/Palette.mm
    src/app/TabBar.mm
    src/app/TerminalPanel.mm
    src/app/TerminalSession.mm
    src/app/TerminalView.mm
    src/app/ChangePopover.mm
    src/app/ChatPanel.mm
    src/app/ChatViews.mm
    src/app/CodeHighlight.mm
    src/app/MarkdownView.mm
    src/app/FindBar.mm
    src/app/FolderWatcher.mm
    src/app/GitRepository.mm
    src/app/SearchPanel.mm
    src/app/SidebarSwitcher.mm
    src/app/StartupTiming.mm
    src/app/SourceControlPanel.mm
    src/app/ExtensionHostService.mm
    src/app/KeybindingService.mm
    src/app/WebviewController.mm
    src/app/ExtensionViews.mm
    src/app/Services.mm)
# The app is built into a folder ending in ".noindex", which Spotlight skips, so development
# builds never show up next to the installed Glasswork.app.
set_target_properties(Glasswork PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_SOURCE_DIR}/resources/Info.plist.in
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/app.noindex
    OUTPUT_NAME Glasswork)
target_compile_options(Glasswork PRIVATE -fobjc-arc -Wall -Wno-unused-parameter)
# Development builds find the extension host next to the sources; the app bundle carries its own copy.
target_compile_definitions(Glasswork PRIVATE GLASSWORK_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
add_custom_command(TARGET Glasswork POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E remove_directory $<TARGET_BUNDLE_CONTENT_DIR:Glasswork>/Resources/ExtensionHost
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/host $<TARGET_BUNDLE_CONTENT_DIR:Glasswork>/Resources/ExtensionHost
    COMMAND ${CMAKE_COMMAND} -E remove_directory $<TARGET_BUNDLE_CONTENT_DIR:Glasswork>/Resources/ExtensionHost/tools)
target_link_libraries(Glasswork PRIVATE glasswork_core
    "-framework AppKit" "-framework CoreText" "-framework QuartzCore" "-framework CoreServices" "-framework WebKit" "-framework UniformTypeIdentifiers")
