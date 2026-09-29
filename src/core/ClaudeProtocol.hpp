#pragma once

#include <nlohmann/json.hpp>

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace gw::claude {

using Json = nlohmann::json;

// ---------------------------------------------------------------------------
// Events: one line of the `claude --output-format stream-json` output, understood.

enum class EventKind {
    SessionInit,        // the session started: id, model, tools, slash commands
    Status,             // "requesting": the model is being called
    MessageStart,       // a new assistant message begins (streaming)
    BlockStart,         // a text, thinking or tool-use block begins
    TextDelta,          // more text for a text block
    ThinkingDelta,      // more thinking for a thinking block
    ToolInputDelta,     // more of a tool call's JSON arguments
    BlockStop,          // that block is complete
    MessageStop,        // the assistant message is complete
    AssistantMessage,   // a complete assistant block (also sent when not streaming)
    UserMessage,        // a user message, or tool results (also used when loading history)
    PermissionRequest,  // Claude wants to use a tool and asks us first
    TurnResult,         // the turn is finished: cost, timing, final text
    RateLimit,          // usage information
    Notice,             // other system messages (permission denied, retries…)
    ControlResponse,    // the answer to a request we sent
    Unknown,
};

struct Event {
    EventKind kind = EventKind::Unknown;
    /// The event exactly as it arrived, for anything the fields below don't cover.
    Json raw;

    std::string sessionId;
    std::string model;
    /// Streaming block number within its message.
    int blockIndex = -1;
    /// "text", "thinking" or "tool_use" for BlockStart.
    std::string blockType;
    /// Text or thinking for deltas; the message for notices and errors.
    std::string text;
    /// Partial JSON for ToolInputDelta.
    std::string partialJson;

    std::string messageId;
    std::string toolId;
    std::string toolName;

    /// Set on events that belong to a sub-agent's work rather than the main conversation.
    bool isSubAgent = false;
    bool isError = false;

    // PermissionRequest
    std::string requestId;
    Json toolInput;

    // TurnResult
    double costUsd = 0;
    long durationMilliseconds = 0;
    long inputTokens = 0;
    long outputTokens = 0;
    long cachedTokens = 0;
    std::string stopReason;

    // SessionInit
    std::vector<std::string> tools;
    std::vector<std::string> slashCommands;
    std::string permissionMode;

    // RateLimit: how much of the 5-hour window is used, 0…1, or -1 if unknown.
    double fiveHourUtilization = -1;
};

/// Understands one line of stream-json output. Lines that aren't JSON give nullopt.
std::optional<Event> parseEvent(std::string_view line);

/// Splits a byte stream (which arrives in arbitrary chunks) into complete lines.
class LineSplitter {
public:
    /// Adds bytes and returns every line that is now complete, without its newline.
    std::vector<std::string> feed(std::string_view bytes);

private:
    std::string pending_;
};

// ---------------------------------------------------------------------------
// The conversation as the UI shows it

enum class Approval {
    NotNeeded,
    Pending,
    Allowed,
    Denied,
};

struct ToolCall {
    std::string id;
    std::string name;
    /// The arguments as JSON text; grows while they stream in.
    std::string inputText;
    Json input;
    bool inputComplete = false;

    std::string resultText;
    bool hasResult = false;
    bool resultIsError = false;
    /// Claude Code's structured result (for example the patch of an edit), if it sent one.
    Json resultDetail;

    Approval approval = Approval::NotNeeded;
    std::string permissionRequestId;

    /// A short line describing what the tool is doing: "Edit  src/main.cpp", "Bash  ls -la".
    std::string summary() const;
    /// The file the tool reads or changes, when it has one.
    std::string filePath() const;
    bool changesFiles() const;
};

struct Block {
    enum class Kind { Text, Thinking, Tool };
    Kind kind = Kind::Text;
    std::string text;
    ToolCall tool;
    bool finished = false;
    int streamIndex = -1;
};

struct Message {
    enum class Role { User, Assistant, Notice };
    Role role = Role::Assistant;
    std::string id;
    std::vector<Block> blocks;
    bool streaming = false;
    /// True for messages that only carry tool results (not shown as a user bubble).
    bool onlyToolResults = false;
    /// Notices only: drawn as an error.
    bool isError = false;
};

struct TurnSummary {
    bool isError = false;
    double costUsd = 0;
    long durationMilliseconds = 0;
    long outputTokens = 0;
    std::string stopReason;
    std::string resultText;
};

/// What an event did to the transcript, so the view can refresh just that part.
struct TranscriptChange {
    bool changed = false;
    /// True if a new message was added (rather than an existing one updated).
    bool addedMessage = false;
    size_t messageIndex = 0;
    /// True if the turn finished with this event.
    bool turnFinished = false;
};

/// Builds up the conversation from events. No I/O, no UI: feed it events, read messages.
class Transcript {
public:
    const std::vector<Message>& messages() const { return messages_; }
    size_t size() const { return messages_.size(); }

    /// Adds what the user typed.
    TranscriptChange addUserMessage(const std::string& text);
    /// Adds a plain informational line (errors, "session ended", …).
    TranscriptChange addNotice(const std::string& text, bool isError = false);

    TranscriptChange apply(const Event& event);

    /// Marks the pending tool call for this permission request as answered.
    bool resolvePermission(const std::string& requestId, bool allowed);
    /// Every tool call still waiting for the user to answer.
    std::vector<const ToolCall*> pendingPermissions() const;

    bool isBusy() const { return busy_; }
    void setBusy(bool busy) { busy_ = busy; }
    const TurnSummary& lastTurn() const { return lastTurn_; }
    const std::string& sessionId() const { return sessionId_; }
    void setSessionId(const std::string& id) { sessionId_ = id; }
    void clear();

    /// When replaying a saved session, plain user messages in the events become messages in
    /// the transcript. While chatting live they don't, because the UI adds them itself.
    void setReplayUserText(bool replay) { replayUserText_ = replay; }

private:
    Message* messageWithId(const std::string& id);
    size_t startAssistantMessage(const std::string& id);
    ToolCall* findTool(const std::string& toolId, size_t* messageIndex = nullptr);
    Block* findStreamBlock(size_t messageIndex, int streamIndex);

    std::vector<Message> messages_;
    /// The assistant message currently streaming in, if any.
    long streamingMessage_ = -1;
    bool busy_ = false;
    bool replayUserText_ = false;
    TurnSummary lastTurn_;
    std::string sessionId_;
};

// ---------------------------------------------------------------------------
// Messages we send

/// A user message in stream-json form, as one line ending in a newline.
std::string userMessageLine(const std::string& text);
/// Answers a permission request. To allow, pass the input the tool should run with (usually
/// the same one it asked with).
std::string permissionResponseLine(const std::string& requestId, bool allow, const Json& input,
                                   const std::string& denyMessage = "");
std::string interruptLine(const std::string& requestId);
std::string setPermissionModeLine(const std::string& requestId, const std::string& mode);
std::string setModelLine(const std::string& requestId, const std::string& model);

// ---------------------------------------------------------------------------
// Past conversations, kept by Claude Code on disk

struct SavedSession {
    std::string id;
    std::string title;  // the first thing the user said
    double modifiedSeconds = 0;  // seconds since 1970
    std::string path;
};

/// The folder Claude Code keeps sessions for a project in.
std::string sessionFolderFor(const std::string& projectPath);
/// Sessions for a project, newest first.
std::vector<SavedSession> listSavedSessions(const std::string& projectPath, size_t limit = 30);
/// Rebuilds a transcript from a saved session file.
Transcript loadSavedSession(const std::string& path);

}  // namespace gw::claude
