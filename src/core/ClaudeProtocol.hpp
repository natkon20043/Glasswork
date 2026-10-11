#pragma once

#include <nlohmann/json.hpp>

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace gw::claude {

using Json = nlohmann::json;

// One line of `claude --output-format stream-json` output -> which kind of Event it parses into.
enum class EventKind {
    SessionInit,
    Status,
    MessageStart,
    BlockStart,
    TextDelta,
    ThinkingDelta,
    ToolInputDelta,
    BlockStop,
    MessageStop,
    AssistantMessage,
    UserMessage,
    PermissionRequest,
    TurnResult,
    RateLimit,
    Notice,
    ControlResponse,
    Unknown,
};

// Permission request from Claude + the user's answer -> state shown on the tool call.
enum class Approval {
    NotNeeded,
    Pending,
    Allowed,
    Denied,
};

// ---- Events

struct Event {
    EventKind kind = EventKind::Unknown;
    /// The line exactly as it arrived, for anything the fields below don't cover.
    Json raw;

    std::string sessionId;
    std::string model;
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

    /// Belongs to a sub-agent's work rather than the main conversation.
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

    // RateLimit: share of the 5-hour window used, 0..1, or -1 if unknown.
    double fiveHourUtilization = -1;
};

/// Lines that aren't JSON give nullopt.
std::optional<Event> parseEvent(std::string_view line);

/// Splits a byte stream that arrives in arbitrary chunks into complete lines.
class LineSplitter {
public:
    // ---- Input
    /// Returns every line now complete, without its newline.
    std::vector<std::string> feed(std::string_view bytes);

private:
    // ---- Private variables
    std::string pending_;
};

// ---- Conversation shown in the UI

struct ToolCall {
    // ---- Getters
    /// One line such as "Edit  src/main.cpp" or "Bash  ls -la".
    std::string summary() const;
    std::string filePath() const;
    bool changesFiles() const;

    // ---- Variables
    std::string id;
    std::string name;
    /// Arguments as JSON text; grows while they stream in.
    std::string inputText;
    Json input;
    bool inputComplete = false;

    std::string resultText;
    bool hasResult = false;
    bool resultIsError = false;
    /// Claude Code's structured result (such as an edit's patch), if sent.
    Json resultDetail;

    Approval approval = Approval::NotNeeded;
    std::string permissionRequestId;
};

struct Block {
    // Block start event -> what the block holds.
    enum class Kind { Text, Thinking, Tool };

    Kind kind = Kind::Text;
    std::string text;
    ToolCall tool;
    bool finished = false;
    int streamIndex = -1;
};

struct Message {
    // Source of a message -> which side of the conversation draws it.
    enum class Role { User, Assistant, Notice };

    Role role = Role::Assistant;
    std::string id;
    std::vector<Block> blocks;
    bool streaming = false;
    /// Carries only tool results, so no user bubble is drawn.
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

/// What an event did to the transcript, so the view refreshes only that part.
struct TranscriptChange {
    bool changed = false;
    bool addedMessage = false;
    size_t messageIndex = 0;
    bool turnFinished = false;
};

/// Builds the conversation from events. No I/O, no UI.
class Transcript {
public:
    // ---- Adding content
    TranscriptChange addUserMessage(const std::string& text);
    TranscriptChange addNotice(const std::string& text, bool isError = false);
    TranscriptChange apply(const Event& event);

    // ---- Permissions
    bool resolvePermission(const std::string& requestId, bool allowed);
    std::vector<const ToolCall*> pendingPermissions() const;

    // ---- Setters
    void setBusy(bool busy) { busy_ = busy; }
    void setSessionId(const std::string& id) { sessionId_ = id; }
    /// True while replaying a saved session, where user messages in events become transcript messages.
    void setReplayUserText(bool replay) { replayUserText_ = replay; }
    void clear();

    // ---- Getters
    const std::vector<Message>& messages() const { return messages_; }
    size_t size() const { return messages_.size(); }
    bool isBusy() const { return busy_; }
    const TurnSummary& lastTurn() const { return lastTurn_; }
    const std::string& sessionId() const { return sessionId_; }

private:
    // ---- Lookup
    Message* messageWithId(const std::string& id);
    size_t startAssistantMessage(const std::string& id);
    ToolCall* findTool(const std::string& toolId, size_t* messageIndex = nullptr);
    Block* findStreamBlock(size_t messageIndex, int streamIndex);

    // ---- One step per event kind (`apply` picks)
    void applyBlockStart(const Event& event, TranscriptChange& change);
    void applyTextDelta(const Event& event, TranscriptChange& change);
    void applyToolInputDelta(const Event& event, TranscriptChange& change);
    void applyBlockStop(const Event& event, TranscriptChange& change);
    void applyAssistantMessage(const Event& event, TranscriptChange& change);
    void applyUserMessage(const Event& event, TranscriptChange& change);
    void applyPermissionRequest(const Event& event, TranscriptChange& change);
    void applyTurnResult(const Event& event, TranscriptChange& change);
    void mergeTextPart(Message& message, const Json& part, const std::string& partType);
    void mergeToolUsePart(Message& message, const Json& part);
    void recordToolResult(ToolCall& tool, const Json& resultPart, const Json& wholeEvent);

    // ---- Private variables
    std::vector<Message> messages_;
    /// Index of the assistant message streaming in now, or -1.
    long streamingMessage_ = -1;
    bool busy_ = false;
    bool replayUserText_ = false;
    TurnSummary lastTurn_;
    std::string sessionId_;
};

// ---- Messages we send (each is one newline-terminated stream-json line)

std::string userMessageLine(const std::string& text);
/// To allow, pass the input the tool should run with (usually the one it asked with).
std::string permissionResponseLine(const std::string& requestId, bool allow, const Json& input,
                                   const std::string& denyMessage = "");
std::string interruptLine(const std::string& requestId);
std::string setPermissionModeLine(const std::string& requestId, const std::string& mode);
std::string setModelLine(const std::string& requestId, const std::string& model);

// ---- Past conversations kept by Claude Code on disk

struct SavedSession {
    std::string id;
    /// The first thing the user said.
    std::string title;
    /// Seconds since 1970.
    double modifiedSeconds = 0;
    std::string path;
};

std::string sessionFolderFor(const std::string& projectPath);
/// Newest first.
std::vector<SavedSession> listSavedSessions(const std::string& projectPath, size_t limit = 30);
Transcript loadSavedSession(const std::string& path);

}  // namespace gw::claude
