# AGENTS.md — working on LLMProbe

This file is the entry point for any agent (or human) continuing work in this
repository. It records how the project is built, the invariants that must not be
broken, and the privacy rules that apply to every change.

中文速览见文末。

---

## 1. What this project is

LLMProbe is a **local-only** diagnostic tool for LLM upstream endpoints. It
answers four questions about an endpoint:

1. Is the upstream reachable and healthy right now?
2. How fast does it stream (TTFT, output tokens/second)?
3. How large is its context window / max output?
4. Which capabilities does it really have — tool calling, vision, audio,
   structured output, reasoning, embeddings, prompt caching, seeds, logprobs?

It is three Swift products built from one engine:

| Product | Path | Purpose |
| --- | --- | --- |
| `LLMProbeCore` | `Sources/LLMProbeCore` | Platform-agnostic engine (Foundation only, no UI) |
| `llmprobe` | `Sources/llmprobe` | CLI: `discover`, `probe`, `import`, `list-sources`, `selftest` |
| `LLMProbeApp` | `Sources/LLMProbeApp` | SwiftUI macOS app (macOS 14+) |

## 2. Commands you will actually need

```bash
swift build                      # everything
swift build --product llmprobe   # CLI only (fast)
swift run llmprobe selftest      # offline engine self check — must stay 100% green
swift run llmprobe discover      # scan local agent configs (read-only)
./scripts/build_app.sh release   # -> ~/Applications/LLMProbe.app (ad-hoc signed)
./scripts/check_privacy.sh       # mandatory before every commit
./scripts/capture_screenshots.sh # regenerate docs screenshots from fictional data
```

**This machine has Command Line Tools only, no Xcode.** `swift test` therefore
cannot import XCTest locally. That is expected and must not be "fixed" by
installing Xcode:

* engine-level checks live in `SelfTest` (`swift run llmprobe selftest`);
* `Tests/LLMProbeCoreTests` wraps the same routine for CI and developers who do
  have Xcode (guarded by `#if canImport(XCTest)`).

Any new pure function in the parsing / classification / budgeting layer **must
get a check in `SelfTest`**. New checks are added as `SelfTest.Check` entries.

## 3. Layout

```
Sources/LLMProbeCore/
  Model/        WireAPI, ProviderKind, ProbeEndpoint, Capability, ProbeResult
  Net/          HTTPClient (buffered + streaming), SSEDecoder, ErrorClassifier
  Providers/    one adapter per wire protocol + ProviderRegistry
  Probes/       ProbeEngine (11 probes) + prompt/parameter tables
  Discovery/    readers for CC Switch, Codex CLI, Claude Code, OpenCode, Gemini CLI,
                Continue, Aider, env vars, local servers
  Support/      Redactor, TokenEstimator, MiniTOML, EndpointStoreFile, SelfTest
Sources/LLMProbeApp/   SwiftUI: sidebar, endpoint detail, editor, discovery sheet
Sources/llmprobe/      CLI entry point (shares the engine with the app)
docs/images/           published screenshots (fictional data only)
scripts/               build, screenshot, privacy and demo-server tooling
```

## 4. Invariants — do not break these

1. **Nothing leaves the machine except the probe requests themselves.** No
   telemetry, no analytics, no crash reporting, no "check for updates" call.
2. **`Redactor` is on every user-visible path.** Any string that could carry a
   credential (headers, error bodies, config snippets, CLI output, `--json`
   output) goes through `Redactor.mask` / `scrub` / `safeHeaders`.
3. **State is written `0600`, in `~/Library/Application Support/LLMProbe`.**
   `state.json` can hold inline credentials copied out of other apps' configs.
   It must never be committed, exported or logged.
4. **`ProbePlan.free` must stay free.** It may only contain probes whose
   `estimatedOutputTokens == 0`. `SelfTest` enforces this.
5. **A capability answer is only `supported` with evidence.** `SupportLevel`
   distinguishes `unknown` from `unsupported` on purpose: never turn a failure
   into a confident "not supported" when the probe simply could not run.
6. **An HTTP 400 that complains about a parameter is evidence, not a failure.**
   `ErrorClassifier.isValidationOnly` + `extractedLimit` feed the context /
   max-output probes. The rejected value appears before the real limit in
   upstream messages, so extraction prefers an explicit marker ("at most",
   ">", "must be") and otherwise the smallest number.
7. **The app bundle is assembled in a temp directory and ad-hoc signed there.**
   This checkout lives in a cloud-synced folder; the file provider re-adds
   Finder metadata, and that makes `codesign` invalidate the bundle (macOS then
   SIGKILLs the app with exit 137). Do not "simplify" `build_app.sh` to build in
   place.
8. **Screenshots are generated, never hand-edited.** They must come from
   `scripts/demo_server.py` + `--state-dir` isolation, contain only the
   fictional "Acme AI" endpoints, and their XMP/text chunks are stripped by
   `scripts/strip_image_metadata.py` before commit.

## 5. Privacy checklist before any commit or push

```bash
./scripts/check_privacy.sh          # tree mode
git config core.hooksPath .githooks # once per clone: runs it on every commit
```

The script fails the commit on: vendor key shapes (`sk-`, `sk-ant-`, `gho_`,
`AIza`, `AKIA`, private keys…), credential-looking assignments, this machine's
absolute paths or `$HOME`, a committed `state.json`, a committed `.app` bundle,
and image metadata chunks.

When reporting to the user, never paste their real base URLs, model ids or keys.
Describe them ("a local proxy on 127.0.0.1") instead.

## 6. Adding support for another vendor

Reuse an existing wire protocol first — most vendors are OpenAI-compatible:

1. `ProviderKind` — add the case and its `displayName` / `defaultBaseURL`.
2. `ProviderInference.kind(from:baseURL:)` — add detection needles.
3. Only if the HTTP contract is genuinely different, add an adapter under
   `Providers/` and register it in `ProviderRegistry`, then extend `WireAPI`.
4. Add a `SelfTest` check for any new inference or parsing rule.

## 7. Roadmap / known gaps

- Windows and Linux: `LLMProbeCore` is Foundation-only and compiles on Linux in
  CI, but **no Windows or Linux build has ever been run on real hardware** —
  the CLI is untested there, and the GUI is macOS-only. The README states this
  explicitly and that statement must stay accurate.
- The context-window probe can spend real input tokens. Keep it behind
  `enableContextSearch` (deep plan only) and respect `tokenBudget`.
- `Discovery` covers the config formats listed above; new agents are welcome as
  long as they follow the `ConfigReader` shape (never mutate the source file —
  discovery is strictly read-only).
- Releases are cumulative: never delete an older tag or release.

## 8. 中文速览

* 本项目是**纯本地**的 LLM 上游体检工具，一个引擎 + CLI + macOS SwiftUI App。
* 本机只有 Command Line Tools，`swift test` 用不了，靠 `swift run llmprobe selftest`（40 项，必须全绿）；新增纯函数逻辑要同步加自检项。
* 提交前必须跑 `./scripts/check_privacy.sh`；绝对不要把本机真实端点、模型名、密钥、`state.json`、`.app` 包提交上去。
* 截图只能来自 `scripts/demo_server.py` 的虚构数据，提交前要剥掉元数据。
* 不新增任何联网上报；认证信息一律走 `Redactor`。
* Windows/Linux 从未在真机验证过，README 里的这句声明必须保持真实。
