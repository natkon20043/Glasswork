#include "ClaudeProtocol.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>

namespace gw::claude {

namespace {

std::string stringField(const Json& object, const char* key) {
    if (!object.is_object()) {
        return std::string();
    }
    auto found = object.find(key);
    if (found == object.end() || !found->is_string()) {
        return std::string();
    }
    return found->get<std::string>();
}

long integerField(const Json& object, const char* key) {
    if (!object.is_object()) {
        return 0;
    }
    auto found = object.find(key);
    if (found == object.end() || !found->is_number()) {
        return 0;
    }
    return found->get<long>();
}

double numberField(const Json& object, const char* key, double fallback = 0) {
    if (!object.is_object()) {
        return fallback;
    }
    auto found = object.find(key);
    if (found == object.end() || !found->is_number()) {
        return fallback;
    }
    return found->get<double>();
}

bool booleanField(const Json& object, const char* key) {
    if (!object.is_object()) {
        return false;
    }
    auto found = object.find(key);
    return found != object.end() && found->is_boolean() && found->get<bool>();
}

/// The text of a tool result, which Claude Code sends either as a string or as a list of
/// content parts.
std::string textOfContent(const Json& content) {
    if (content.is_string()) {
        return content.get<std::string>();
    }
    std::string text;
    if (content.is_array()) {
        for (const Json& part : content) {
            if (part.is_object() && stringField(part, "type") == "text") {
                if (!text.empty()) {
                    text += "\n";
                }
                text += stringField(part, "text");
            }
        }
    }
    return text;
}

std::string baseName(const std::string& path) {
    size_t slash = path.rfind('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string firstLine(const std::string& text, size_t limit) {
    size_t newline = text.find('\n');
    std::string line = newline == std::string::npos ? text : text.substr(0, newline);
    if (line.size() > limit) {
        line = line.substr(0, limit) + "…";
    }
    return line;
}

Event parseStreamEvent(const Json& outer) {
    Event event;
    event.raw = outer;
    event.sessionId = stringField(outer, "session_id");
    event.isSubAgent = outer.contains("parent_tool_use_id") && !outer["parent_tool_use_id"].is_null();

    const Json& inner = outer.contains("event") ? outer["event"] : Json::object();
    std::string type = stringField(inner, "type");

    if (type == "message_start") {
        event.kind = EventKind::MessageStart;
        const Json& message = inner.contains("message") ? inner["message"] : Json::object();
        event.messageId = stringField(message, "id");
        event.model = stringField(message, "model");
    } else if (type == "content_block_start") {
        event.kind = EventKind::BlockStart;
        event.blockIndex = static_cast<int>(integerField(inner, "index"));
        const Json& block = inner.contains("content_block") ? inner["content_block"] : Json::object();
        event.blockType = stringField(block, "type");
        event.toolId = stringField(block, "id");
        event.toolName = stringField(block, "name");
    } else if (type == "content_block_delta") {
        event.blockIndex = static_cast<int>(integerField(inner, "index"));
        const Json& delta = inner.contains("delta") ? inner["delta"] : Json::object();
        std::string deltaType = stringField(delta, "type");
        if (deltaType == "text_delta") {
            event.kind = EventKind::TextDelta;
            event.text = stringField(delta, "text");
        } else if (deltaType == "thinking_delta") {
            event.kind = EventKind::ThinkingDelta;
            event.text = stringField(delta, "thinking");
        } else if (deltaType == "input_json_delta") {
            event.kind = EventKind::ToolInputDelta;
            event.partialJson = stringField(delta, "partial_json");
        }
    } else if (type == "content_block_stop") {
        event.kind = EventKind::BlockStop;
        event.blockIndex = static_cast<int>(integerField(inner, "index"));
    } else if (type == "message_stop") {
        event.kind = EventKind::MessageStop;
    }
    return event;
}

}  // namespace

// ---------------------------------------------------------------------------
// Parsing events

std::optional<Event> parseEvent(std::string_view line) {
    Json outer = Json::parse(line.begin(), line.end(), nullptr, false);
    if (outer.is_discarded() || !outer.is_object()) {
        return std::nullopt;
    }

    std::string type = stringField(outer, "type");

    if (type == "stream_event") {
        return parseStreamEvent(outer);
    }

    Event event;
    event.raw = outer;
    event.sessionId = stringField(outer, "session_id");
    if (event.sessionId.empty()) {
        event.sessionId = stringField(outer, "sessionId");
    }
    bool sideChain = booleanField(outer, "isSidechain");
    bool hasParentTool = outer.contains("parent_tool_use_id") && !outer["parent_tool_use_id"].is_null();
    event.isSubAgent = sideChain || hasParentTool;

    if (type == "system") {
        std::string subtype = stringField(outer, "subtype");
        if (subtype == "init") {
            event.kind = EventKind::SessionInit;
            event.model = stringField(outer, "model");
            event.permissionMode = stringField(outer, "permissionMode");
            if (outer.contains("tools") && outer["tools"].is_array()) {
                for (const Json& tool : outer["tools"]) {
                    if (tool.is_string()) {
                        event.tools.push_back(tool.get<std::string>());
                    }
                }
            }
            if (outer.contains("slash_commands") && outer["slash_commands"].is_array()) {
                for (const Json& command : outer["slash_commands"]) {
                    if (command.is_string()) {
                        event.slashCommands.push_back(command.get<std::string>());
                    }
                }
            }
        } else if (subtype == "status") {
            event.kind = EventKind::Status;
            event.text = stringField(outer, "status");
        } else if (subtype == "api_retry" || subtype == "error") {
            event.kind = EventKind::Notice;
            event.text = stringField(outer, "message");
            if (event.text.empty()) {
                event.text = stringField(outer, "error");
            }
            if (event.text.empty()) {
                event.text = subtype == "api_retry" ? "Retrying the request…" : "Something went wrong.";
            }
            event.isError = subtype == "error";
        }
        return event;
    }

    if (type == "assistant") {
        event.kind = EventKind::AssistantMessage;
        const Json& message = outer.contains("message") ? outer["message"] : Json::object();
        event.messageId = stringField(message, "id");
        event.model = stringField(message, "model");
        return event;
    }

    if (type == "user") {
        event.kind = EventKind::UserMessage;
        // Notes Claude Code adds on its own behalf ("caveat: …") are not the user's words.
        if (booleanField(outer, "isMeta")) {
            event.kind = EventKind::Unknown;
        }
        return event;
    }

    if (type == "control_request") {
        const Json& request = outer.contains("request") ? outer["request"] : Json::object();
        if (stringField(request, "subtype") == "can_use_tool") {
            event.kind = EventKind::PermissionRequest;
            event.requestId = stringField(outer, "request_id");
            event.toolName = stringField(request, "tool_name");
            event.toolId = stringField(request, "tool_use_id");
            event.toolInput = request.contains("input") ? request["input"] : Json::object();
        }
        return event;
    }

    if (type == "control_response") {
        event.kind = EventKind::ControlResponse;
        const Json& response = outer.contains("response") ? outer["response"] : Json::object();
        event.requestId = stringField(response, "request_id");
        event.isError = stringField(response, "subtype") == "error";
        event.text = stringField(response, "error");
        return event;
    }

    if (type == "result") {
        event.kind = EventKind::TurnResult;
        event.isError = booleanField(outer, "is_error");
        event.text = stringField(outer, "result");
        event.costUsd = numberField(outer, "total_cost_usd");
        event.durationMilliseconds = integerField(outer, "duration_ms");
        event.stopReason = stringField(outer, "stop_reason");
        if (outer.contains("usage") && outer["usage"].is_object()) {
            const Json& usage = outer["usage"];
            event.inputTokens = integerField(usage, "input_tokens");
            event.outputTokens = integerField(usage, "output_tokens");
            event.cachedTokens = integerField(usage, "cache_read_input_tokens");
        }
        return event;
    }

    if (type == "rate_limit_event") {
        event.kind = EventKind::RateLimit;
        const Json& info = outer.contains("rate_limit_info") ? outer["rate_limit_info"] : Json::object();
        if (info.contains("unifiedWindows") && info["unifiedWindows"].is_object()) {
            const Json& windows = info["unifiedWindows"];
            if (windows.contains("five_hour") && windows["five_hour"].is_object()) {
                event.fiveHourUtilization = numberField(windows["five_hour"], "utilization", -1);
            }
        }
        return event;
    }

    return event;  // kind stays Unknown
}

std::vector<std::string> LineSplitter::feed(std::string_view bytes) {
    std::vector<std::string> lines;
    pending_.append(bytes);
    size_t start = 0;
    while (true) {
        size_t newline = pending_.find('\n', start);
        if (newline == std::string::npos) {
            break;
        }
        if (newline > start) {
            lines.push_back(pending_.substr(start, newline - start));
        }
        start = newline + 1;
    }
    pending_.erase(0, start);
    return lines;
}

// ---------------------------------------------------------------------------
// Tool calls

std::string ToolCall::filePath() const {
    if (!input.is_object()) {
        return std::string();
    }
    for (const char* key : {"file_path", "notebook_path", "path"}) {
        std::string value = stringField(input, key);
        if (!value.empty()) {
            return value;
        }
    }
    return std::string();
}

bool ToolCall::changesFiles() const {
    return name == "Write" || name == "Edit" || name == "MultiEdit" || name == "NotebookEdit";
}

std::string ToolCall::summary() const {
    if (!inputComplete || !input.is_object()) {
        return name;
    }
    std::string path = filePath();
    if (!path.empty()) {
        return name + "  " + baseName(path);
    }
    if (name == "Bash") {
        return name + "  " + firstLine(stringField(input, "command"), 90);
    }
    if (name == "Glob" || name == "Grep") {
        return name + "  " + firstLine(stringField(input, "pattern"), 90);
    }
    if (name == "WebFetch") {
        return name + "  " + firstLine(stringField(input, "url"), 90);
    }
    if (name == "WebSearch") {
        return name + "  " + firstLine(stringField(input, "query"), 90);
    }
    if (name == "Task" || name == "Agent") {
        return name + "  " + firstLine(stringField(input, "description"), 90);
    }
    if (name == "TodoWrite") {
        return "Update to-do list";
    }
    return name;
}

// ---------------------------------------------------------------------------
// Transcript

void Transcript::clear() {
    messages_.clear();
    streamingMessage_ = -1;
    busy_ = false;
    lastTurn_ = TurnSummary();
}

TranscriptChange Transcript::addUserMessage(const std::string& text) {
    Message message;
    message.role = Message::Role::User;
    Block block;
    block.kind = Block::Kind::Text;
    block.text = text;
    block.finished = true;
    message.blocks.push_back(std::move(block));
    messages_.push_back(std::move(message));
    streamingMessage_ = -1;

    TranscriptChange change;
    change.changed = true;
    change.addedMessage = true;
    change.messageIndex = messages_.size() - 1;
    return change;
}

TranscriptChange Transcript::addNotice(const std::string& text, bool isError) {
    Message message;
    message.role = Message::Role::Notice;
    message.isError = isError;
    Block block;
    block.kind = Block::Kind::Text;
    block.text = text;
    block.finished = true;
    message.blocks.push_back(std::move(block));
    messages_.push_back(std::move(message));

    TranscriptChange change;
    change.changed = true;
    change.addedMessage = true;
    change.messageIndex = messages_.size() - 1;
    return change;
}

Message* Transcript::messageWithId(const std::string& id) {
    if (id.empty()) {
        return nullptr;
    }
    // Recent messages are the likely ones.
    for (size_t index = messages_.size(); index-- > 0;) {
        if (messages_[index].role == Message::Role::Assistant && messages_[index].id == id) {
            return &messages_[index];
        }
    }
    return nullptr;
}

size_t Transcript::startAssistantMessage(const std::string& id) {
    Message message;
    message.role = Message::Role::Assistant;
    message.id = id;
    message.streaming = true;
    messages_.push_back(std::move(message));
    streamingMessage_ = static_cast<long>(messages_.size()) - 1;
    return messages_.size() - 1;
}

ToolCall* Transcript::findTool(const std::string& toolId, size_t* messageIndex) {
    if (toolId.empty()) {
        return nullptr;
    }
    for (size_t index = messages_.size(); index-- > 0;) {
        for (Block& block : messages_[index].blocks) {
            if (block.kind == Block::Kind::Tool && block.tool.id == toolId) {
                if (messageIndex != nullptr) {
                    *messageIndex = index;
                }
                return &block.tool;
            }
        }
    }
    return nullptr;
}

Block* Transcript::findStreamBlock(size_t messageIndex, int streamIndex) {
    for (Block& block : messages_[messageIndex].blocks) {
        if (block.streamIndex == streamIndex && !block.finished) {
            return &block;
        }
    }
    return nullptr;
}

bool Transcript::resolvePermission(const std::string& requestId, bool allowed) {
    for (Message& message : messages_) {
        for (Block& block : message.blocks) {
            if (block.kind == Block::Kind::Tool && block.tool.permissionRequestId == requestId &&
                block.tool.approval == Approval::Pending) {
                block.tool.approval = allowed ? Approval::Allowed : Approval::Denied;
                return true;
            }
        }
    }
    return false;
}

std::vector<const ToolCall*> Transcript::pendingPermissions() const {
    std::vector<const ToolCall*> pending;
    for (const Message& message : messages_) {
        for (const Block& block : message.blocks) {
            if (block.kind == Block::Kind::Tool && block.tool.approval == Approval::Pending) {
                pending.push_back(&block.tool);
            }
        }
    }
    return pending;
}

namespace {

/// Records in `change` that the message at `index` was added or changed.
void markChanged(TranscriptChange& change, size_t index, bool added) {
    change.changed = true;
    change.addedMessage = added;
    change.messageIndex = index;
}

}  // namespace

TranscriptChange Transcript::apply(const Event& event) {
    TranscriptChange change;
    if (event.isSubAgent) {
        return change;  // the sub-agent's own chatter is summarised by its tool call
    }

    switch (event.kind) {
        case EventKind::SessionInit:
            if (!event.sessionId.empty()) {
                sessionId_ = event.sessionId;
            }
            break;

        case EventKind::Status:
            busy_ = true;
            break;

        case EventKind::MessageStart:
            markChanged(change, startAssistantMessage(event.messageId), true);
            break;

        case EventKind::BlockStart:
            applyBlockStart(event, change);
            break;

        case EventKind::TextDelta:
        case EventKind::ThinkingDelta:
            applyTextDelta(event, change);
            break;

        case EventKind::ToolInputDelta:
            applyToolInputDelta(event, change);
            break;

        case EventKind::BlockStop:
            applyBlockStop(event, change);
            break;

        case EventKind::MessageStop:
            if (streamingMessage_ >= 0) {
                size_t index = static_cast<size_t>(streamingMessage_);
                messages_[index].streaming = false;
                streamingMessage_ = -1;
                markChanged(change, index, false);
            }
            break;

        case EventKind::AssistantMessage:
            applyAssistantMessage(event, change);
            break;

        case EventKind::UserMessage:
            applyUserMessage(event, change);
            break;

        case EventKind::PermissionRequest:
            applyPermissionRequest(event, change);
            break;

        case EventKind::TurnResult:
            applyTurnResult(event, change);
            break;

        case EventKind::Notice:
            if (!event.text.empty()) {
                TranscriptChange added = addNotice(event.text, event.isError);
                markChanged(change, added.messageIndex, true);
            }
            break;

        case EventKind::RateLimit:
        case EventKind::ControlResponse:
        case EventKind::Unknown:
            break;
    }
    return change;
}

/// A new piece of the streaming reply begins: some text, some thinking or a tool call.
void Transcript::applyBlockStart(const Event& event, TranscriptChange& change) {
    if (streamingMessage_ < 0) {
        startAssistantMessage(std::string());
        change.addedMessage = true;
    }
    size_t index = static_cast<size_t>(streamingMessage_);
    Block block;
    block.streamIndex = event.blockIndex;
    if (event.blockType == "thinking") {
        block.kind = Block::Kind::Thinking;
    } else if (event.blockType == "tool_use") {
        block.kind = Block::Kind::Tool;
        block.tool.id = event.toolId;
        block.tool.name = event.toolName;
    } else {
        block.kind = Block::Kind::Text;
    }
    messages_[index].blocks.push_back(std::move(block));
    markChanged(change, index, change.addedMessage);
}

/// More words arrived for a text or thinking block of the streaming reply.
void Transcript::applyTextDelta(const Event& event, TranscriptChange& change) {
    if (streamingMessage_ < 0) {
        return;
    }
    size_t index = static_cast<size_t>(streamingMessage_);
    Block* block = findStreamBlock(index, event.blockIndex);
    if (block != nullptr) {
        block->text += event.text;
        markChanged(change, index, false);
    }
}

/// More of a tool call's input (JSON, sent in pieces) arrived.
void Transcript::applyToolInputDelta(const Event& event, TranscriptChange& change) {
    if (streamingMessage_ < 0) {
        return;
    }
    size_t index = static_cast<size_t>(streamingMessage_);
    Block* block = findStreamBlock(index, event.blockIndex);
    if (block != nullptr && block->kind == Block::Kind::Tool) {
        block->tool.inputText += event.partialJson;
        markChanged(change, index, false);
    }
}

/// A piece of the streaming reply is complete. For a tool call, its input JSON is now whole.
void Transcript::applyBlockStop(const Event& event, TranscriptChange& change) {
    if (streamingMessage_ < 0) {
        return;
    }
    size_t index = static_cast<size_t>(streamingMessage_);
    Block* block = findStreamBlock(index, event.blockIndex);
    if (block == nullptr) {
        return;
    }
    block->finished = true;
    if (block->kind == Block::Kind::Tool && !block->tool.inputComplete) {
        Json parsed = Json::parse(block->tool.inputText, nullptr, false);
        if (parsed.is_object()) {
            block->tool.input = parsed;
            block->tool.inputComplete = true;
        }
    }
    markChanged(change, index, false);
}

/// The complete assistant message. While streaming we already have most of it; when replaying a
/// saved session this is the only place the message appears.
void Transcript::applyAssistantMessage(const Event& event, TranscriptChange& change) {
    const Json& message = event.raw.contains("message") ? event.raw["message"] : Json::object();
    if (!message.contains("content") || !message["content"].is_array()) {
        return;
    }

    Message* existingMessage = messageWithId(event.messageId);
    size_t index = 0;
    bool added = false;
    if (existingMessage == nullptr) {
        index = startAssistantMessage(event.messageId);
        added = true;
        messages_[index].streaming = false;
        streamingMessage_ = -1;
    } else {
        index = static_cast<size_t>(existingMessage - messages_.data());
    }

    for (const Json& part : message["content"]) {
        std::string partType = stringField(part, "type");
        Message& current = messages_[index];
        if (partType == "text" || partType == "thinking") {
            mergeTextPart(current, part, partType);
        } else if (partType == "tool_use") {
            mergeToolUsePart(current, part);
        }
    }
    markChanged(change, index, added);
}

/// Puts a finished text or thinking part into the message, filling the block that was streaming
/// in if there is one, or adding a new block.
void Transcript::mergeTextPart(Message& message, const Json& part, const std::string& partType) {
    Block::Kind kind = partType == "text" ? Block::Kind::Text : Block::Kind::Thinking;
    std::string text = stringField(part, partType == "text" ? "text" : "thinking");

    // The most recent block of this kind that hasn't been closed.
    Block* open = nullptr;
    for (size_t position = message.blocks.size(); position-- > 0;) {
        Block& candidate = message.blocks[position];
        if (candidate.kind == kind && !candidate.finished) {
            open = &candidate;
            break;
        }
    }
    if (open != nullptr) {
        if (!text.empty()) {
            open->text = text;
        }
    } else if (!text.empty() || kind == Block::Kind::Thinking) {
        Block block;
        block.kind = kind;
        block.text = text;
        block.finished = true;
        message.blocks.push_back(std::move(block));
    }
}

/// Puts a finished tool call into the message, completing the one that was streaming in if any.
void Transcript::mergeToolUsePart(Message& message, const Json& part) {
    std::string toolId = stringField(part, "id");
    ToolCall* existing = nullptr;
    for (Block& candidate : message.blocks) {
        if (candidate.kind == Block::Kind::Tool && candidate.tool.id == toolId) {
            existing = &candidate.tool;
        }
    }
    if (existing == nullptr) {
        Block block;
        block.kind = Block::Kind::Tool;
        block.tool.id = toolId;
        block.tool.name = stringField(part, "name");
        block.finished = true;
        message.blocks.push_back(std::move(block));
        existing = &message.blocks.back().tool;
    }
    if (part.contains("input")) {
        existing->input = part["input"];
        existing->inputText = part["input"].dump();
        existing->inputComplete = true;
    }
}

/// A user message: either what the user typed (only when replaying a saved session) or the
/// results of tool calls.
void Transcript::applyUserMessage(const Event& event, TranscriptChange& change) {
    const Json& message = event.raw.contains("message") ? event.raw["message"] : Json::object();
    if (!message.contains("content")) {
        return;
    }
    const Json& content = message["content"];

    // Plain text from the user (only present when replaying a saved session; while
    // chatting, the UI already added what the user typed).
    if (replayUserText_) {
        std::string text;
        if (content.is_string()) {
            text = content.get<std::string>();
        } else if (content.is_array()) {
            for (const Json& part : content) {
                if (stringField(part, "type") == "text") {
                    text += stringField(part, "text");
                }
            }
        }
        bool internalNote = !text.empty() && text[0] == '<';
        if (!text.empty() && !internalNote) {
            TranscriptChange added = addUserMessage(text);
            markChanged(change, added.messageIndex, true);
        }
    }

    if (!content.is_array()) {
        return;
    }
    for (const Json& part : content) {
        if (stringField(part, "type") != "tool_result") {
            continue;
        }
        size_t messageIndex = 0;
        ToolCall* tool = findTool(stringField(part, "tool_use_id"), &messageIndex);
        if (tool == nullptr) {
            continue;
        }
        recordToolResult(*tool, part, event.raw);
        markChanged(change, messageIndex, false);
    }
}

/// Stores what a tool call returned, and settles its approval: a call that was still waiting
/// for an answer was allowed if it ran, denied if it failed.
void Transcript::recordToolResult(ToolCall& tool, const Json& resultPart, const Json& wholeEvent) {
    tool.hasResult = true;
    tool.resultIsError = booleanField(resultPart, "is_error");
    tool.resultText = resultPart.contains("content") ? textOfContent(resultPart["content"]) : std::string();
    if (wholeEvent.contains("tool_use_result")) {
        tool.resultDetail = wholeEvent["tool_use_result"];
    } else if (wholeEvent.contains("toolUseResult")) {
        tool.resultDetail = wholeEvent["toolUseResult"];
    }
    if (tool.approval == Approval::Pending) {
        tool.approval = tool.resultIsError ? Approval::Denied : Approval::Allowed;
    }
}

/// Claude asks whether it may run a tool.
void Transcript::applyPermissionRequest(const Event& event, TranscriptChange& change) {
    size_t messageIndex = 0;
    ToolCall* tool = findTool(event.toolId, &messageIndex);
    if (tool == nullptr) {
        // The request came before we saw the tool call itself: show it anyway.
        size_t index = startAssistantMessage(std::string());
        messages_[index].streaming = false;
        streamingMessage_ = -1;
        Block block;
        block.kind = Block::Kind::Tool;
        block.tool.id = event.toolId;
        block.tool.name = event.toolName;
        block.tool.input = event.toolInput;
        block.tool.inputText = event.toolInput.dump();
        block.tool.inputComplete = true;
        block.finished = true;
        messages_[index].blocks.push_back(std::move(block));
        tool = &messages_[index].blocks.back().tool;
        messageIndex = index;
        change.addedMessage = true;
    }
    tool->approval = Approval::Pending;
    tool->permissionRequestId = event.requestId;
    if (!event.toolInput.is_null()) {
        tool->input = event.toolInput;
        tool->inputComplete = true;
    }
    markChanged(change, messageIndex, change.addedMessage);
}

/// The turn is over: remember how it went and close everything that was still open.
void Transcript::applyTurnResult(const Event& event, TranscriptChange& change) {
    busy_ = false;
    lastTurn_.isError = event.isError;
    lastTurn_.costUsd = event.costUsd;
    lastTurn_.durationMilliseconds = event.durationMilliseconds;
    lastTurn_.outputTokens = event.outputTokens;
    lastTurn_.stopReason = event.stopReason;
    lastTurn_.resultText = event.text;
    if (!event.sessionId.empty()) {
        sessionId_ = event.sessionId;
    }
    // Anything still waiting for an answer was cut short by the end of the turn.
    for (Message& message : messages_) {
        for (Block& block : message.blocks) {
            if (block.kind == Block::Kind::Tool && block.tool.approval == Approval::Pending) {
                block.tool.approval = Approval::Denied;
            }
        }
        message.streaming = false;
    }
    streamingMessage_ = -1;
    if (event.isError && !event.text.empty()) {
        TranscriptChange added = addNotice(event.text, true);
        markChanged(change, added.messageIndex, true);
    }
    change.changed = true;
    change.turnFinished = true;
}

// ---------------------------------------------------------------------------
// Messages we send

namespace {

std::string line(const Json& message) {
    return message.dump() + "\n";
}

std::string controlRequestLine(const std::string& requestId, Json request) {
    Json message = {{"type", "control_request"}, {"request_id", requestId}, {"request", std::move(request)}};
    return line(message);
}

}  // namespace

std::string userMessageLine(const std::string& text) {
    Json message = {{"type", "user"}, {"message", {{"role", "user"}, {"content", text}}}};
    return line(message);
}

std::string permissionResponseLine(const std::string& requestId, bool allow, const Json& input,
                                   const std::string& denyMessage) {
    Json answer;
    if (allow) {
        answer = {{"behavior", "allow"}, {"updatedInput", input}};
    } else {
        answer = {{"behavior", "deny"},
                  {"message", denyMessage.empty() ? "The user declined this action." : denyMessage}};
    }
    Json message = {{"type", "control_response"},
                    {"response", {{"subtype", "success"}, {"request_id", requestId}, {"response", answer}}}};
    return line(message);
}

std::string interruptLine(const std::string& requestId) {
    return controlRequestLine(requestId, {{"subtype", "interrupt"}});
}

std::string setPermissionModeLine(const std::string& requestId, const std::string& mode) {
    return controlRequestLine(requestId, {{"subtype", "set_permission_mode"}, {"mode", mode}});
}

std::string setModelLine(const std::string& requestId, const std::string& model) {
    return controlRequestLine(requestId, {{"subtype", "set_model"}, {"model", model}});
}

// ---------------------------------------------------------------------------
// Saved sessions

std::string sessionFolderFor(const std::string& projectPath) {
    const char* home = std::getenv("HOME");
    std::string folder = home != nullptr ? home : "";
    folder += "/.claude/projects/";
    for (unsigned char character : projectPath) {
        folder += std::isalnum(character) ? static_cast<char>(character) : '-';
    }
    return folder;
}

namespace {

/// Reads up to `limit` bytes from the start or the end of a file.
std::string readChunk(const std::string& path, size_t limit, bool fromEnd) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) {
        return std::string();
    }
    size_t size = static_cast<size_t>(file.tellg());
    size_t count = std::min(size, limit);
    file.seekg(fromEnd ? static_cast<std::streamoff>(size - count) : 0);
    std::string data(count, '\0');
    file.read(data.data(), static_cast<std::streamsize>(count));
    return data;
}

std::string titleForSession(const std::string& path) {
    // Claude Code writes a short generated title into the file; the newest one is last.
    std::string tail = readChunk(path, 256 * 1024, true);
    size_t position = tail.rfind("\"type\":\"ai-title\"");
    if (position != std::string::npos) {
        size_t lineStart = tail.rfind('\n', position);
        lineStart = lineStart == std::string::npos ? 0 : lineStart + 1;
        size_t lineEnd = tail.find('\n', position);
        if (lineEnd == std::string::npos) {
            lineEnd = tail.size();
        }
        Json entry = Json::parse(tail.substr(lineStart, lineEnd - lineStart), nullptr, false);
        std::string title = stringField(entry, "aiTitle");
        if (!title.empty()) {
            return title;
        }
    }

    // Otherwise, the first thing the user said.
    std::string head = readChunk(path, 256 * 1024, false);
    size_t start = 0;
    while (start < head.size()) {
        size_t end = head.find('\n', start);
        if (end == std::string::npos) {
            break;
        }
        Json entry = Json::parse(head.substr(start, end - start), nullptr, false);
        start = end + 1;
        if (!entry.is_object() || stringField(entry, "type") != "user" || booleanField(entry, "isMeta")) {
            continue;
        }
        const Json& message = entry.contains("message") ? entry["message"] : Json::object();
        std::string text;
        if (message.contains("content")) {
            text = textOfContent(message["content"]);
        }
        if (!text.empty() && text[0] != '<') {
            return firstLine(text, 80);
        }
    }
    return "Conversation";
}

}  // namespace

std::vector<SavedSession> listSavedSessions(const std::string& projectPath, size_t limit) {
    std::vector<SavedSession> sessions;
    std::error_code error;
    std::string folder = sessionFolderFor(projectPath);
    for (const auto& entry : std::filesystem::directory_iterator(folder, error)) {
        if (entry.path().extension() != ".jsonl") {
            continue;
        }
        struct stat info;
        if (stat(entry.path().c_str(), &info) != 0) {
            continue;
        }
        SavedSession session;
        session.id = entry.path().stem().string();
        session.path = entry.path().string();
        session.modifiedSeconds = static_cast<double>(info.st_mtimespec.tv_sec);
        sessions.push_back(std::move(session));
    }
    std::sort(sessions.begin(), sessions.end(),
              [](const SavedSession& a, const SavedSession& b) { return a.modifiedSeconds > b.modifiedSeconds; });
    if (sessions.size() > limit) {
        sessions.resize(limit);
    }
    for (SavedSession& session : sessions) {
        session.title = titleForSession(session.path);
    }
    return sessions;
}

Transcript loadSavedSession(const std::string& path) {
    Transcript transcript;
    transcript.setReplayUserText(true);
    transcript.setSessionId(std::filesystem::path(path).stem().string());
    std::ifstream file(path);
    std::string text;
    while (std::getline(file, text)) {
        std::optional<Event> event = parseEvent(text);
        if (event) {
            transcript.apply(*event);
        }
    }
    transcript.setReplayUserText(false);
    transcript.setBusy(false);
    return transcript;
}

}  // namespace gw::claude
