# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Appearance setting (Settings → Appearance): **System / Light / Dark**, applied immediately and remembered between launches. `--appearance system|light|dark` forces it for screenshots and layout checks.
- Documentation screenshots are now captured per language and per appearance (Chinese and English, light and dark home screens, discovery and settings), and the dashboards in the READMEs switch automatically with the reader's GitHub theme.

### Changed

- Discovery no longer writes to the endpoint list on its own. The sheet shows what it read, and a single blue **Import N endpoints** button applies it; **Cancel** leaves the list untouched.
- The Settings window is built with an explicit `NSHostingController` (`sizingOptions = []`) instead of SwiftUI's `Settings` scene. That scene let SwiftUI resize the window to its content while the grouped form re-laid itself out, which ended in `NSGenericException: ... more Layout Window passes ...` and aborted the app on macOS 26/27.
- The self test grew to 42 checks with the appearance-preference parsing/resolution rules.

## [0.1.0] — 2026-10-03

First public release. macOS is the only platform that has actually been built and run; Windows and Linux are best-effort and **untested** (see the README).

### Added

**Engine (`LLMProbeCore`)**

- Five wire-API adapters: `openai-chat`, `openai-responses`, `anthropic-messages`, `google-gemini`, `ollama-chat`.
- Endpoint inference from hostname, configuration shape and model-id convention, with a manual override.
- 28 vendor presets (OpenAI, Anthropic, Google Gemini, Azure OpenAI, OpenRouter, DeepSeek, Moonshot / Kimi, Zhipu GLM, Alibaba DashScope, MiniMax, Xiaomi MiMo, iFlow, SiliconFlow, Groq, Mistral, xAI, Together AI, Fireworks AI, Perplexity, Cerebras, Ollama, LM Studio, MLX server, vLLM, LiteLLM, One API / New API, Command Code, Custom).
- Eleven probes: reachability, model catalog, chat completion, streaming speed, tool calling, vision input, structured output, context window, max output tokens, reasoning, embeddings.
- Three plans — `free` (0 completion tokens), `quick` (default) and `deep` (payload context search, 3 speed samples) — each with a hard token budget.
- Speed measurement with TTFT, output tokens/second and median sampling.
- Error classifier that separates authentication, authorization, model-not-found, invalid request, context overflow, rate limit, quota, upstream 5xx, timeout, transport and decode failures, and extracts the real context/output limit out of an error string instead of trusting the rejected value.
- Capability findings with evidence levels (`supported` / `partial` / `unsupported` / `unknown`) and provenance (`probe`, `metadata`, `local config`, `heuristic`), merged through a cache so repeat runs cost nothing.
- Unified redaction of every outbound string, plus token estimation and a `0600` state/cache store.

**Discovery**

- CC Switch reader: `~/.cc-switch/cc-switch.db`, always opened read-only, covering six `app_type`s (`codex`, `claude`, `claude-desktop`, `gemini`, `opencode`, `hermes`) and flagging the active provider.
- Readers for Codex CLI (`config.toml`, `CODEX_HOME`-aware), Claude Code, OpenCode, Gemini CLI, GitHub Copilot CLI, Qwen Code, DeepSeek Harness, Kimi Code CLI, MiniMax Code, ZCode, MiMo Code, iFlow CLI, Trae Agent, Pi, OpenClaw, Hermes Agent, Continue and Aider.
- Shared JSONC / TOML / YAML-subset decoding and provider/model extraction for heterogeneous harness formats.
- Cursor CLI and Amazon Q Developer CLI sources report installation/unsupported status without guessing hosted base URLs.
- Explicit disclaimer for automatic detection that is not verified across every tool version.
- Environment-variable and local-server (port scan) sources.
- Merged, de-duplicated endpoint list with per-source status messages.
- Fictional demo discovery result for screenshots and documentation.

**macOS app (`LLMProbeApp`)**

- SwiftUI interface: sidebar, endpoint detail, metric cards, capability matrix, per-probe results, endpoint editor, discovery sheet and speed trend chart.
- Discovery sheet that imports selected endpoints in one click.
- Settings window (`⌘,`): language, probe defaults, data location, history cleanup, about.
- Full bilingual UI (Chinese / English) switchable at runtime, remembered between launches. The default follows the Mac: Chinese system → Chinese, English system → English, any other system language → English.
- About pane with the project repository, the author and a voluntary GitHub Sponsors link.
- Deterministic window sizing plus a delayed AppKit-hosted SwiftUI fallback window so launch cannot remain running without a main window.
- English application command-menu labels for consistency with English system menus.
- Polished SwiftUI/AppKit-native layout using `ContentUnavailableView`, `Grid`, `LabeledContent`, `DisclosureGroup`, `Form` and `TabView`.
- Bilingual discovery notes and relative timestamps; screenshots use fictional Acme data only.

**CLI (`llmprobe`)**

- `discover`, `import`, `probe` (`--index`, `--all`, or `--url` + `--model`), `list-sources`, `selftest`, `version`, `help`.
- `--json` for machine consumption: stable English vocabulary, one document per run (`probe --all --json` emits `{verdict, count, reports}`), no interaction, exit code = worst verdict.
- **English only, by design**: the GUI is bilingual but the CLI is not, so scripts and agents match on stable strings. The language is pinned once at start-up, before any probe runs.
- Human-readable report aligned by display width, so a wide column never breaks the table.
- 40-check offline self test (`selftest`) covering redaction, token estimation, JSONC/TOML/YAML parsing, multi-agent provider extraction, product naming, SSE framing, endpoint de-duplication, wire-API inference, error classification, plan budgets, capability caching, state round-trip, system-language mapping and bilingual coverage.

**Tooling**

- `scripts/build_app.sh` — assembles and ad-hoc signs `LLMProbe.app` outside the checkout for native, ARM64 or x86_64 targets, then verifies the signature and binary architecture.
- `scripts/install_cli.sh` — installs the CLI to `/usr/local/bin` with a `~/.local/bin` fallback.
- `scripts/check_privacy.sh` — credential, machine-path and screenshot-metadata gate, wired into `.githooks/pre-commit`.
- `scripts/package_release.sh` — builds and verifies separate Apple silicon (ARM64) and Intel (x86_64) release zips with per-file checksums and `SHA256SUMS`.
- `scripts/capture_screenshots.sh` + `scripts/demo_server.py` — reproducible fictional screenshots with metadata stripping.
- `scripts/strip_image_metadata.py` — removes PNG text/EXIF chunks with no image dependency.
- CI: macOS build + self test + unit tests, best-effort Linux CLI build, and the privacy gate.

### Fixed

- Empty state no longer draws its action buttons on top of the support note: the note was pinned with a bottom `overlay`, so a window shorter than the ideal size overprinted one on the other. The whole block is now a single linear stack that cannot overlap.
- The sidebar is never a blank column: with no endpoints it shows an explicit placeholder instead of an empty list, and the auto-discover / settings / add bar stays reachable.
- The main window is repaired whenever it ends up below the declared 1080x680 minimum, not only at the fixed delays that run during the first eight seconds of a launch.
- `llmprobe <command> --help` prints usage instead of running the command. `llmprobe import --help` previously performed a real import and wrote endpoints into the live state file.
- Commands reject options they do not implement (`--no-locl`, `--jason`, `--json` on `list-sources`) instead of silently ignoring the typo.

### Known limitations

- The GUI is macOS-only; Linux has no SwiftUI/AppKit surface.
- Ad-hoc signed builds trip Gatekeeper on first launch; there is no notarisation.
- Windows and Linux have never been run by the maintainer.
- Automatic configuration detection for some agent tools—especially MiniMax Code, ZCode and Trae Agent—is unverified across versions and provided for reference only.
- Azure OpenAI needs a deployment-specific URL and is entered manually.

[0.1.0]: https://github.com/Lucas-Qh-Lai/llm-probe/releases/tag/v0.1.0
