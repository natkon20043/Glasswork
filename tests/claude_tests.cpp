// Tests for the Claude Code protocol layer: event parsing, the conversation model, and
// saved sessions. Uses event streams shaped like the ones the real CLI produces.

#include "TestHarness.hpp"

#include "ClaudeProtocol.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <unistd.h>

namespace {

using gw::claude::Approval;
using gw::claude::Block;
using gw::claude::Event;
using gw::claude::EventKind;
using gw::claude::Json;
using gw::claude::Message;
using gw::claude::Transcript;

/// Feeds several lines to a transcript, the way the live session does.
void feed(Transcript& transcript, const std::vector<std::string>& lines) {
    for (const std::string& line : lines) {
        std::optional<Event> event = gw::claude::parseEvent(line);
        if (event) {
            transcript.apply(*event);
        }
    }
}

std::string streamEvent(const Json& inner) {
    return Json{{"type", "stream_event"}, {"event", inner}, {"session_id", "s1"}}.dump();
}

std::string temporaryFolder(const std::string& label) {
    std::filesystem::path path = std::filesystem::temp_directory_path() /
                                 ("glasswork-" + label + "-" + std::to_string(getpid()));
    std::filesystem::remove_all(path);
    std::filesystem::create_directories(path);
    return std::filesystem::canonical(path).string();
}

// A whole turn where Claude thinks, writes some text, then asks to write a file.
std::vector<std::string> aTurnWithAToolCall() {
    return {
        R"({"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet-5-5","permissionMode":"default","tools":["Bash","Write"],"slash_commands":["debug","init"]})",
        R"({"type":"system","subtype":"status","status":"requesting","session_id":"s1"})",
        streamEvent({{"type", "message_start"}, {"message", {{"id", "msg_1"}, {"model", "claude-sonnet-5-5"}}}}),
        streamEvent({{"type", "content_block_start"}, {"index", 0}, {"content_block", {{"type", "thinking"}}}}),
        streamEvent({{"type", "content_block_delta"}, {"index", 0}, {"delta", {{"type", "thinking_delta"}, {"thinking", "Hmm."}}}}),
        streamEvent({{"type", "content_block_stop"}, {"index", 0}}),
        streamEvent({{"type", "content_block_start"}, {"index", 1}, {"content_block", {{"type", "text"}, {"text", ""}}}}),
        streamEvent({{"type", "content_block_delta"}, {"index", 1}, {"delta", {{"type", "text_delta"}, {"text", "I'll create "}}}}),
        streamEvent({{"type", "content_block_delta"}, {"index", 1}, {"delta", {{"type", "text_delta"}, {"text", "the file."}}}}),
        R"({"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"I'll create the file."}]}})",
        streamEvent({{"type", "content_block_stop"}, {"index", 1}}),
        streamEvent({{"type", "content_block_start"}, {"index", 2}, {"content_block", {{"type", "tool_use"}, {"id", "toolu_1"}, {"name", "Write"}, {"input", Json::object()}}}}),
        streamEvent({{"type", "content_block_delta"}, {"index", 2}, {"delta", {{"type", "input_json_delta"}, {"partial_json", "{\"file_path\": \"/tmp/pro"}}}}),
        streamEvent({{"type", "content_block_delta"}, {"index", 2}, {"delta", {{"type", "input_json_delta"}, {"partial_json", "ject/hello.txt\", \"content\": \"hi\"}"}}}}),
        R"({"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Write","input":{"file_path":"/tmp/project/hello.txt","content":"hi"}}]}})",
        streamEvent({{"type", "content_block_stop"}, {"index", 2}}),
        streamEvent({{"type", "message_stop"}}),
        R"({"type":"control_request","request_id":"req-9","request":{"subtype":"can_use_tool","tool_name":"Write","tool_use_id":"toolu_1","input":{"file_path":"/tmp/project/hello.txt","content":"hi"}}})",
    };
}

// ---------------------------------------------------------------------------

TEST(lineSplitterHandlesSplitAndCoalescedChunks) {
    gw::claude::LineSplitter splitter;
    CHECK(splitter.feed("{\"a\":").empty());
    std::vector<std::string> lines = splitter.feed("1}\n{\"b\":2}\n{\"c\"");
    CHECK_EQ(lines.size(), size_t(2));
    CHECK_EQ(lines[0], std::string("{\"a\":1}"));
    CHECK_EQ(lines[1], std::string("{\"b\":2}"));
    lines = splitter.feed(":3}\n\n");
    CHECK_EQ(lines.size(), size_t(1));
    CHECK_EQ(lines[0], std::string("{\"c\":3}"));
}

TEST(parseEventRecognisesTheMainKinds) {
    auto init = gw::claude::parseEvent(aTurnWithAToolCall()[0]);
    CHECK(init && init->kind == EventKind::SessionInit);
    CHECK_EQ(init->model, std::string("claude-sonnet-5-5"));
    CHECK_EQ(init->tools.size(), size_t(2));
    CHECK_EQ(init->slashCommands.size(), size_t(2));

    auto permission = gw::claude::parseEvent(aTurnWithAToolCall().back());
    CHECK(permission && permission->kind == EventKind::PermissionRequest);
    CHECK_EQ(permission->requestId, std::string("req-9"));
    CHECK_EQ(permission->toolName, std::string("Write"));
    CHECK_EQ(permission->toolInput["content"].get<std::string>(), std::string("hi"));

    auto result = gw::claude::parseEvent(
        R"({"type":"result","subtype":"success","is_error":false,"result":"Done.","total_cost_usd":0.05,"duration_ms":1900,"usage":{"input_tokens":4,"output_tokens":149,"cache_read_input_tokens":27228},"stop_reason":"end_turn"})");
    CHECK(result && result->kind == EventKind::TurnResult);
    CHECK_EQ(result->outputTokens, long(149));
    CHECK_EQ(result->cachedTokens, long(27228));
    CHECK(result->costUsd > 0.049 && result->costUsd < 0.051);

    auto limit = gw::claude::parseEvent(
        R"({"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.07}}}})");
    CHECK(limit && limit->kind == EventKind::RateLimit);
    CHECK(limit->fiveHourUtilization > 0.069 && limit->fiveHourUtilization < 0.071);

    CHECK(!gw::claude::parseEvent("not json at all").has_value());
    auto unknown = gw::claude::parseEvent(R"({"type":"something_new"})");
    CHECK(unknown && unknown->kind == EventKind::Unknown);
}

TEST(transcriptBuildsAStreamedTurn) {
    Transcript transcript;
    transcript.addUserMessage("make a file");
    feed(transcript, aTurnWithAToolCall());

    CHECK_EQ(transcript.sessionId(), std::string("s1"));
    CHECK(transcript.isBusy());
    CHECK_EQ(transcript.size(), size_t(2));
    CHECK(transcript.messages()[0].role == Message::Role::User);

    const Message& reply = transcript.messages()[1];
    CHECK(reply.role == Message::Role::Assistant);
    CHECK(!reply.streaming);
    CHECK_EQ(reply.blocks.size(), size_t(3));
    CHECK(reply.blocks[0].kind == Block::Kind::Thinking);
    CHECK_EQ(reply.blocks[0].text, std::string("Hmm."));
    CHECK(reply.blocks[1].kind == Block::Kind::Text);
    CHECK_EQ(reply.blocks[1].text, std::string("I'll create the file."));
    CHECK(reply.blocks[1].finished);

    const gw::claude::ToolCall& tool = reply.blocks[2].tool;
    CHECK_EQ(tool.name, std::string("Write"));
    CHECK(tool.inputComplete);
    CHECK_EQ(tool.filePath(), std::string("/tmp/project/hello.txt"));
    CHECK_EQ(tool.summary(), std::string("Write  hello.txt"));
    CHECK(tool.changesFiles());
    CHECK(tool.approval == Approval::Pending);
    CHECK_EQ(tool.permissionRequestId, std::string("req-9"));
    CHECK_EQ(transcript.pendingPermissions().size(), size_t(1));

    // The user allows it; the file is written; the turn ends.
    CHECK(transcript.resolvePermission("req-9", true));
    CHECK(transcript.pendingPermissions().empty());
    feed(transcript, {
        R"({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"File created"}]},"tool_use_result":{"type":"create","filePath":"/tmp/project/hello.txt"}})",
        R"({"type":"assistant","message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"Done."}]}})",
        R"({"type":"result","subtype":"success","is_error":false,"result":"Done.","total_cost_usd":0.01,"duration_ms":900,"usage":{"output_tokens":20}})",
    });

    const gw::claude::ToolCall& finished = transcript.messages()[1].blocks[2].tool;
    CHECK(finished.hasResult);
    CHECK_EQ(finished.resultText, std::string("File created"));
    CHECK_EQ(finished.resultDetail["type"].get<std::string>(), std::string("create"));
    CHECK(!transcript.isBusy());
    CHECK_EQ(transcript.lastTurn().outputTokens, long(20));
    // The follow-up message "Done." is a second assistant message.
    CHECK_EQ(transcript.size(), size_t(3));
    CHECK_EQ(transcript.messages()[2].blocks[0].text, std::string("Done."));
}

TEST(transcriptReportsChangesForTheView) {
    Transcript transcript;
    auto started = gw::claude::parseEvent(streamEvent({{"type", "message_start"}, {"message", {{"id", "m"}}}}));
    gw::claude::TranscriptChange first = transcript.apply(*started);
    CHECK(first.changed && first.addedMessage && first.messageIndex == 0);

    auto block = gw::claude::parseEvent(
        streamEvent({{"type", "content_block_start"}, {"index", 0}, {"content_block", {{"type", "text"}}}}));
    gw::claude::TranscriptChange second = transcript.apply(*block);
    CHECK(second.changed && !second.addedMessage && second.messageIndex == 0);

    auto done = gw::claude::parseEvent(R"({"type":"result","is_error":false,"result":"x"})");
    gw::claude::TranscriptChange third = transcript.apply(*done);
    CHECK(third.turnFinished);
}

TEST(transcriptShowsErrorsAndIgnoresSubAgentChatter) {
    Transcript transcript;
    feed(transcript, {
        R"({"type":"assistant","parent_tool_use_id":"toolu_task","message":{"id":"sub","role":"assistant","content":[{"type":"text","text":"sub agent talking"}]}})",
        R"({"type":"result","subtype":"error_during_execution","is_error":true,"result":"Credit balance is too low"})",
    });
    CHECK_EQ(transcript.size(), size_t(1));
    CHECK(transcript.messages()[0].role == Message::Role::Notice);
    CHECK_EQ(transcript.messages()[0].blocks[0].text, std::string("Credit balance is too low"));
}

TEST(pendingPermissionsAreDeniedWhenTheTurnEnds) {
    Transcript transcript;
    feed(transcript, aTurnWithAToolCall());
    CHECK_EQ(transcript.pendingPermissions().size(), size_t(1));
    feed(transcript, {R"({"type":"result","is_error":false,"result":""})"});
    CHECK(transcript.pendingPermissions().empty());
    CHECK(transcript.messages()[0].blocks[2].tool.approval == Approval::Denied);
}

TEST(toolSummariesAreShortAndReadable) {
    Transcript transcript;
    feed(transcript, {
        R"({"type":"assistant","message":{"id":"a","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la\nrm nothing"}},{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"TODO"}},{"type":"tool_use","id":"t3","name":"Read","input":{"file_path":"/a/b/c.cpp"}}]}})",
    });
    const auto& blocks = transcript.messages()[0].blocks;
    CHECK_EQ(blocks[0].tool.summary(), std::string("Bash  ls -la"));
    CHECK_EQ(blocks[1].tool.summary(), std::string("Grep  TODO"));
    CHECK_EQ(blocks[2].tool.summary(), std::string("Read  c.cpp"));
    CHECK(!blocks[2].tool.changesFiles());
}

TEST(aLongSummaryIsNeverCutInsideACharacter) {
    // 89 ASCII letters, then "é" (two bytes) straddling the 90-byte cut.
    std::string command = std::string(89, 'a') + "\xC3\xA9 and more";
    gw::claude::ToolCall tool;
    tool.name = "Bash";
    tool.input = Json{{"command", command}};
    tool.inputComplete = true;
    std::string summary = tool.summary();
    std::string expected = "Bash  " + std::string(89, 'a') + "…";
    CHECK_EQ(summary, expected);
}

TEST(messagesWeSendAreValidStreamJson) {
    Json user = Json::parse(gw::claude::userMessageLine("hello \"world\"\nline two"));
    CHECK_EQ(user["type"].get<std::string>(), std::string("user"));
    CHECK_EQ(user["message"]["content"].get<std::string>(), std::string("hello \"world\"\nline two"));
    CHECK(gw::claude::userMessageLine("x").back() == '\n');

    Json input = {{"file_path", "/a"}};
    Json allow = Json::parse(gw::claude::permissionResponseLine("req-1", true, input));
    CHECK_EQ(allow["type"].get<std::string>(), std::string("control_response"));
    CHECK_EQ(allow["response"]["request_id"].get<std::string>(), std::string("req-1"));
    CHECK_EQ(allow["response"]["response"]["behavior"].get<std::string>(), std::string("allow"));
    CHECK_EQ(allow["response"]["response"]["updatedInput"]["file_path"].get<std::string>(), std::string("/a"));

    Json deny = Json::parse(gw::claude::permissionResponseLine("req-2", false, input, "Not that file"));
    CHECK_EQ(deny["response"]["response"]["behavior"].get<std::string>(), std::string("deny"));
    CHECK_EQ(deny["response"]["response"]["message"].get<std::string>(), std::string("Not that file"));

    Json interrupt = Json::parse(gw::claude::interruptLine("r3"));
    CHECK_EQ(interrupt["request"]["subtype"].get<std::string>(), std::string("interrupt"));
    Json mode = Json::parse(gw::claude::setPermissionModeLine("r4", "acceptEdits"));
    CHECK_EQ(mode["request"]["mode"].get<std::string>(), std::string("acceptEdits"));
}

TEST(sessionFolderNamesMatchClaudeCodesEncoding) {
    setenv("HOME", "/Users/tester", 1);
    CHECK_EQ(gw::claude::sessionFolderFor("/Users/nate/Code/Glasswork"),
             std::string("/Users/tester/.claude/projects/-Users-nate-Code-Glasswork"));
    CHECK_EQ(gw::claude::sessionFolderFor("/tmp/a b.c"), std::string("/Users/tester/.claude/projects/-tmp-a-b-c"));
}

TEST(savedSessionsAreListedAndReplayed) {
    std::string home = temporaryFolder("claude-home");
    setenv("HOME", home.c_str(), 1);
    std::string project = "/Users/tester/proj";
    std::string folder = gw::claude::sessionFolderFor(project);
    std::filesystem::create_directories(folder);

    {
        std::ofstream file(folder + "/aaaa-1111.jsonl");
        file << R"({"type":"mode","mode":"normal","sessionId":"aaaa-1111"})" << "\n";
        file << R"({"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>ignore me</local-command-caveat>"}})" << "\n";
        file << R"({"type":"user","message":{"role":"user","content":"Fix the login bug"},"sessionId":"aaaa-1111"})" << "\n";
        file << R"({"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Let me look."}]}})" << "\n";
        file << R"({"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/login.cpp"}}]}})" << "\n";
        file << R"({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"file body"}]}]},"toolUseResult":{"type":"text"}})" << "\n";
        file << R"({"type":"assistant","isSidechain":true,"message":{"id":"side","role":"assistant","content":[{"type":"text","text":"hidden"}]}})" << "\n";
        file << R"({"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Found it."}]}})" << "\n";
        file << R"({"type":"ai-title","aiTitle":"Login bug fix","sessionId":"aaaa-1111"})" << "\n";
    }
    {
        std::ofstream file(folder + "/bbbb-2222.jsonl");
        file << R"({"type":"user","message":{"role":"user","content":"Older question about tests"}})" << "\n";
    }
    // Make the second file older.
    std::filesystem::last_write_time(folder + "/bbbb-2222.jsonl",
                                     std::filesystem::file_time_type::clock::now() - std::chrono::hours(48));

    std::vector<gw::claude::SavedSession> sessions = gw::claude::listSavedSessions(project);
    CHECK_EQ(sessions.size(), size_t(2));
    CHECK_EQ(sessions[0].id, std::string("aaaa-1111"));
    CHECK_EQ(sessions[0].title, std::string("Login bug fix"));
    CHECK_EQ(sessions[1].title, std::string("Older question about tests"));

    Transcript transcript = gw::claude::loadSavedSession(sessions[0].path);
    CHECK_EQ(transcript.sessionId(), std::string("aaaa-1111"));
    CHECK_EQ(transcript.size(), size_t(3));  // user, assistant (text + tool), assistant
    CHECK(transcript.messages()[0].role == Message::Role::User);
    CHECK_EQ(transcript.messages()[0].blocks[0].text, std::string("Fix the login bug"));
    CHECK_EQ(transcript.messages()[1].blocks.size(), size_t(2));
    CHECK(transcript.messages()[1].blocks[1].tool.hasResult);
    CHECK_EQ(transcript.messages()[1].blocks[1].tool.resultText, std::string("file body"));
    CHECK_EQ(transcript.messages()[2].blocks[0].text, std::string("Found it."));
    CHECK(!transcript.isBusy());

    std::filesystem::remove_all(home);
}

}  // namespace

int main() {
    return harness::runAllTests();
}
