# CapyBuddy — AI Features Plan

The current CapyBuddy ships five features (`SpaceShortcut`, `Screenshot`, `Caffeine`, `Clipboard`, `SystemMonitor`). This document plans the **AI phase** that comes next.

Goals (from the prior conversation):
- An "AI Quick Panel" — global hotkey opens a chat / one-shot input, calls a local LLM, shows the answer.
- Backend pluggable across **Apple Foundation Models (on-device)**, **LM Studio (`localhost:1234`)**, and **Ollama (`localhost:11434`)**.
- AI integrations into existing features: Clipboard (translate / rewrite / summarize) and Screenshot (vision Q&A).
- Web search is lower priority — only useful when paired with an LLM that can synthesize results.

Out of scope for this phase: cloud APIs (Anthropic/OpenAI), agents, file-system tools, embeddings/RAG. Keep the surface tight.

---

## 0. Conventions used below

- Each feature follows the existing `Feature` protocol pattern (`CapyBuddy/Core/Feature.swift`) with its own folder under `CapyBuddy/Features/`.
- Anything that touches the network / system framework gets a **protocol abstraction + mock** so the unit test target (`CapyBuddyTests`) can drive it deterministically — same pattern used for `PowerAssertionHolder` (Caffeine) and `PasteboardReading` (Clipboard).
- ID allocation in `project.pbxproj`: continue the existing scheme. New IDs should be `2C…0250+` (file refs), `3D…0350+` (build files), `1B…0204+` (groups). New test IDs `2C…030A+`, `3D…040A+`. Avoid clashing with anything already used (see the existing pbxproj for the high-water mark).

---

## 1. AI backend abstraction (the foundation)

**New folder:** `CapyBuddy/AI/` (top-level — not under `Features/`, because multiple features will use it).

### 1.1 Core types

```swift
// CapyBuddy/AI/AIBackend.swift

enum AIRole: String, Codable { case system, user, assistant }

struct AIMessage: Codable, Equatable {
    let role: AIRole
    let content: String
    var images: [Data]? = nil   // PNG bytes; nil when the message is text-only
}

struct AIRequest: Equatable {
    var messages: [AIMessage]
    var maxTokens: Int? = nil
    var temperature: Double? = nil
}

/// Backend-agnostic streaming chunk. Always text — image-out is not in scope.
enum AIChunk {
    case delta(String)
    case done
    case error(Error)
}

@MainActor
protocol AIBackend: AnyObject {
    /// Display name in Settings ("Apple Intelligence", "LM Studio (localhost:1234)", …).
    var displayName: String { get }

    /// Cheap probe — used to pick a default backend at first launch and to grey
    /// out unavailable options in Settings. Should not throw; return false if
    /// the network is down or the framework isn't present.
    func isAvailable() async -> Bool

    /// True iff this backend can accept `AIMessage.images`. Apple Foundation
    /// Models supports vision in macOS 26; most local servers don't.
    var supportsVision: Bool { get }

    /// Fire-and-forget streaming. The implementation pumps `AIChunk` values
    /// onto the AsyncStream until `.done` or `.error`.
    func stream(_ request: AIRequest) -> AsyncStream<AIChunk>
}
```

### 1.2 Three implementations

```
CapyBuddy/AI/Backends/
├── AppleFoundationBackend.swift      // wraps `import FoundationModels`
├── LMStudioBackend.swift             // OpenAI-compatible /v1/chat/completions
└── OllamaBackend.swift               // Ollama /api/chat, also OpenAI-compat /v1/chat
```

**AppleFoundationBackend** — uses macOS 26's `FoundationModels` framework. Single instance of `LanguageModelSession`; map `AIMessage` to its transcript format. `supportsVision = true` when the user's device supports Apple Intelligence vision (gate on `SystemLanguageModel.default.availability`). Keep this one in a `#if canImport(FoundationModels)` block so older SDKs still compile.

**LMStudioBackend / OllamaBackend** — both speak the OpenAI Chat Completions wire protocol; share an `OpenAICompatibleClient` helper. Configurable base URL + optional API key. Stream via `URLSession.bytes(for:)` parsing SSE `data: ...` lines. `supportsVision = false` by default — leave room for the user to flip it on per-backend if their model supports it (LLaVA / Qwen2-VL etc.) but don't auto-detect.

### 1.3 Backend selection

```swift
// CapyBuddy/AI/AIBackendRegistry.swift

@MainActor
final class AIBackendRegistry: ObservableObject {
    static let shared = AIBackendRegistry()
    @Published private(set) var selected: AIBackend
    @Published private(set) var available: [AIBackend]
    func select(id: String) { ... }    // persist to UserDefaults("ai.backendID")
}
```

Pick at first launch in this order: `AppleFoundation` → `LMStudio` → `Ollama`. If none are available, the AI features still render but every action shows "No AI backend available — see Settings".

### 1.4 Tests

- `OpenAICompatibleClientTests` — feed a fake `URLSession`/`URLProtocol` SSE stream, assert chunks roll out as `.delta` / `.done`. (Use `URLProtocol` subclassing — same trick as e.g. Alamofire's tests.)
- `AppleFoundationBackendTests` — only what we can test without the framework: the message-to-prompt mapping (extracted as a `nonisolated static` pure function).
- `AIBackendRegistryTests` — first-launch selection logic with mock backends whose `isAvailable()` we control.

**Files / tests for stage 1:** ~6 production files, ~3 test files, ~15 tests.

---

## 2. AI Quick Panel (Feature)

**Folder:** `CapyBuddy/Features/AIPanel/`

The flagship feature. Global hotkey (`⌘⇧Space` proposed, configurable) → floating panel → ask → streaming answer.

### 2.1 Files

```
CapyBuddy/Features/AIPanel/
├── AIPanelFeature.swift         // Feature impl + hotkey + window
├── AIPanelHotkeyStore.swift     // mirror of ClipboardHotkeyStore
├── AIPanelController.swift      // ObservableObject driving the SwiftUI view
├── AIPanelWindow.swift          // NSPanel + NSHostingController
├── AIPanelView.swift            // SwiftUI: input + streaming output + history
└── AIPanelSettingsView.swift    // backend picker + hotkey + system prompt
```

### 2.2 Behavior

- **Hotkey** → toggle panel. Reuse `HotkeyTap`. Default: `⌘⇧Space` (will conflict with Spotlight on some setups; surface that in Settings with a hint).
- **Panel layout**:
  - Top: TextField (multiline, `⏎` submits, `⇧⏎` newline).
  - Middle: streaming response area (markdown-rendered — use `Text(AttributedString(markdown:))` for the MVP; no code-block syntax highlighting in v1).
  - Footer: small line — selected backend name + token-usage / latency if the backend reports it.
- **Conversation buffer**: keep the last N turns in memory (default 8). New panel-open starts fresh; explicit "New chat" button clears.
- **Streaming**: subscribe to `backend.stream(request)`, append `.delta` chunks live. Cancel on `Esc` / panel-close.
- **Errors**: render inline ("LM Studio is not reachable on `localhost:1234`. Is it running?").

### 2.3 Settings

- Backend picker (radio-style; greyed-out for unavailable).
- LM Studio / Ollama base URL editor + "Test connection" button.
- System prompt textarea (persists in UserDefaults).
- Hotkey customizer (reuse the same UI Screenshot/Clipboard use).
- Conversation length slider (4-32).

### 2.4 Tests

- `AIPanelControllerTests` — feed a mock backend that emits scripted chunks, assert the controller's published state transitions (`.idle` → `.streaming` → `.done`).
- `AIPanelControllerCancellationTests` — verify `Esc` cancels the in-flight stream.
- Backend-switching test — change backend mid-conversation, next request goes to the new one.

**Files / tests for stage 2:** ~6 production files, ~2 test files, ~12 tests.

---

## 3. AI × Clipboard

**No new feature** — extend the existing `ClipboardFeature`.

### 3.1 What to add

In `ClipboardHistoryView` (the popup), each row gets a hover-revealed AI menu:

> 🪄 Translate to English
> 🪄 Rewrite (concise)
> 🪄 Summarize
> 🪄 Explain

Picking one: open the AI Panel pre-populated with that prompt + the clipboard text as user message; stream the response. After completion the user can `⌘C` the result and the panel closes (or stays open, configurable).

Alternative path: from the menu-bar dropdown's recent-5 list, right-click an item → same AI submenu.

### 3.2 Files

```
CapyBuddy/Features/Clipboard/
├── ClipboardAIActions.swift     // canned-prompt enum + prompt templates
└── (extend ClipboardHistoryView + ClipboardFeature)
```

`ClipboardAIActions` is a `nonisolated enum` with a `func prompt(for text: String) -> String` per case — testable as pure data transformation.

### 3.3 Tests

- `ClipboardAIActionsTests` — assert each preset's prompt template substitutes the input correctly and produces the expected `AIMessage` array.

**Files / tests for stage 3:** ~1 production file + view edits, ~1 test file, ~6 tests.

---

## 4. AI × Screenshot (vision)

**Extend `ScreenshotFeature`.** Only enable the new entry point when `AIBackendRegistry.shared.selected.supportsVision == true`.

### 4.1 What to add

After a capture, the floating annotation toolbar (`AnnotationToolbarPanel`) gets a new button: **"Ask AI…"**. Tapping it:
1. Renders the current canvas (image + annotations) to a PNG.
2. Opens the AI Panel pre-populated with that PNG attached + a default prompt placeholder ("What do you see?").
3. User can edit the prompt before sending.

Common queries the placeholder rotates through (purely cosmetic): "Translate the text in this image" / "Explain this error" / "Describe this UI".

### 4.2 Files

```
CapyBuddy/Features/Screenshot/
├── ScreenshotAIBridge.swift     // turns a captured image + prompt into AIRequest
└── (extend AnnotationToolbarPanel + ScreenshotManager hand-off)
```

### 4.3 Tests

- `ScreenshotAIBridgeTests` — given a fake image and prompt, assert the produced `AIRequest` has the right structure (one user message, one image attached, prompt text matches).
- Test that the bridge falls back to a text-only request when the selected backend reports `supportsVision == false`.

**Files / tests for stage 4:** ~1 production file + view edits, ~1 test file, ~4 tests.

---

## 5. Web Search (last, optional)

Only worth doing once the AI Panel is solid, because the value is "let the LLM search the web for me," not "give me a search box."

### 5.1 Approach

- Add a single tool: `web_search(query) -> [SearchResult]`.
- Backend implementations: **DuckDuckGo HTML scrape** (no API key, brittle) or **Brave Search API** (free tier available, needs key). Start with DDG and surface "Add Brave key" as an upgrade in Settings.
- Wire it as an OpenAI-style tool/function call:
  - Apple Foundation: use its tool API.
  - LM Studio / Ollama: use OpenAI tool-call schema; many local models follow it (e.g. Qwen2.5, Llama 3.1).
- In the AI Panel, surface tool calls as collapsed "🔍 Searched: '…'" rows above the answer.

### 5.2 Files

```
CapyBuddy/AI/Tools/
├── WebSearchTool.swift          // protocol + DDG/Brave implementations
└── ToolDispatcher.swift         // routes assistant tool_calls to handlers
```

### 5.3 Tests

- `WebSearchToolTests` — feed canned HTML/JSON to the parser, assert structured `SearchResult` extraction.
- `ToolDispatcherTests` — feed a fake assistant message containing a `tool_calls` array, assert the dispatcher invokes the right tool with the right args.

**Files / tests for stage 5:** ~3 production files, ~2 test files, ~8 tests.

---

## 6. Implementation order

1. **Stage 1: backend abstraction** (~1.5 days) — `AIBackend` protocol + Apple Foundation + LM Studio + Ollama + registry + tests. Nothing user-visible yet, but everything else depends on it.
2. **Stage 2: AI Quick Panel** (~2 days) — first user-visible AI feature, validates the backend abstraction.
3. **Stage 3: Clipboard AI actions** (~0.5 day) — small, demonstrates re-use of the panel.
4. **Stage 4: Screenshot vision** (~0.5 day) — gated on Apple Foundation availability.
5. **Stage 5: Web search** (~1 day) — only if 1-4 land cleanly. Can be deferred indefinitely.

**Total estimate:** ~5.5 days for the whole AI phase. The first two stages (backend + panel) are ~3.5 days and stand on their own — usable shipping point even if 3-5 are deferred.

---

## 7. Key risks / unknowns

- **`FoundationModels` API surface** — at planning time the framework is new (macOS 26). Validate the `LanguageModelSession` / `Transcript` types compile against the SDK actually installed on the dev machine before committing to the Apple-backend contract. If the API is too different from the OpenAI-style request shape, accept some impedance in `AppleFoundationBackend` rather than warping the protocol.
- **Hotkey conflicts** — `⌘⇧Space` collides with default Spotlight on some setups. Pick a default that's free; let the user remap. Same `HotkeyTap` infrastructure as Screenshot/Clipboard, so no new code.
- **Streaming SSE parsing** — the OpenAI/LM Studio SSE format is `data: {json}\n\n` with `data: [DONE]` terminator. Handle partial lines across chunks. Existing test pattern (URLProtocol fake) covers this fine but needs care.
- **Memory / image size** — base64-encoded PNGs in HTTP bodies can be multi-MB. Cap captured screenshot resolution before sending (downscale long edge to 1568px — common vision-model sweet spot).
- **Privacy** — when the active backend is anything other than Apple Foundation Models, prompts and images leave the device (even if just to localhost — but to a process the user runs, not Apple/Anthropic/OpenAI). Surface a per-backend privacy line in Settings ("On-device. Nothing leaves your Mac." vs "Sent to localhost:1234 (LM Studio).").

---

## 8. Suggested first-conversation kickoff

When opening the next conversation, paste or reference this file and start with:

> Read `design/AI_PLAN.md`. Implement Stage 1 (backend abstraction + three implementations + registry + unit tests). Stop after Stage 1 builds and all tests pass — I want to review the protocol shape before you build the AI Panel.

That keeps the same iteration cadence as the Caffeine / Clipboard / SystemMonitor work: one stage, tests green, hand-off, review, next stage.
