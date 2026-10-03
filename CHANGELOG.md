# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-10-03

First public release. macOS is the only platform that has actually been built and run; Windows and Linux are best-effort and **untested** (see the README).

### Added

**Engine (`LLMProbeCore`)**

- Five wire-API adapters: `openai-chat`, `openai-responses`, `anthropic-messages`, `google-gemini`, `ollama-chat`.
- Endpoint inference from hostname, configuration shape and model-id convention, with a manual override.
- 25 vendor presets (OpenAI, Anthropic, Google, Azure OpenAI, OpenRouter, DeepSeek, Moonshot, Zhipu, DashScope, SiliconFlow, Groq, Mistral, xAI, Together, Fireworks, Perplexity, Cerebras, Ollama, LM Studio, MLX, vLLM, LiteLLM, One API, Command Code, Custom).
- Eleven probes: reachability, model catalog, chat completion, streaming speed, tool calling, vision input, structured output, context window, max output tokens, reasoning, embeddings.
- Three plans — `free` (0 completion tokens), `quick` (default) and `deep` (payload context search, 3 speed samples) — each with a hard token budget.
- Speed measurement with TTFT, output tokens/second and median sampling.
- Error classifier that separates authentication, authorization, model-not-found, invalid request, context overflow, rate limit, quota, upstream 5xx, timeout, transport and decode failures, and extracts the real context/output limit out of an error string instead of trusting the rejected value.
- Capability findings with evidence levels (`supported` / `partial` / `unsupported` / `unknown`) and provenance (`probe`, `metadata`, `local config`, `heuristic`), merged through a cache so repeat runs cost nothing.
- Unified redaction of every outbound string, plus token estimation and a `0600` state/cache store.

**Discovery**

- CC Switch reader: `~/.cc-switch/cc-switch.db`, always opened read-only, covering six `app_type`s (`codex`, `claude`, `claude-desktop`, `gemini`, `opencode`, `hermes`) and flagging the active provider.
- Readers for OpenAI Codex (`config.toml`, `CODEX_HOME`-aware), Claude Code, opencode, Gemini CLI, Continue and Aider.
- Environment-variable and local-server (port scan) sources.
- Merged, de-duplicated endpoint list with per-source status messages.
- Fictional demo discovery result for screenshots and documentation.

**macOS app (`LLMProbeApp`)**

- SwiftUI interface: sidebar, endpoint detail, metric cards, capability matrix, per-probe results, endpoint editor, discovery sheet and speed trend chart.
- Discovery sheet that imports selected endpoints in one click.
- Settings window (`⌘,`): language, probe defaults, data location, history cleanup, about.
- Full bilingual UI (Chinese / English) switchable at runtime, remembered between launches. The default follows the Mac: Chinese system → Chinese, English system → English, any other system language → English.
- About pane with the project repository, the author and a voluntary GitHub Sponsors link.
- Deterministic window sizing, native menus and keyboard shortcuts.

**CLI (`llmprobe`)**

- `discover`, `import`, `probe` (`--index`, `--all`, or `--url` + `--model`), `list-sources`, `selftest`, `version`, `help`.
- `--json` for machine consumption: stable English vocabulary, one document per run (`probe --all --json` emits `{verdict, count, reports}`), no interaction, exit code = worst verdict.
- **English only, by design**: the GUI is bilingual but the CLI is not, so scripts and agents match on stable strings. The language is pinned once at start-up, before any probe runs.
- Human-readable report aligned by display width, so a wide column never breaks the table.
- 32-check offline self test (`selftest`) covering redaction, token estimation, TOML parsing, SSE framing, endpoint de-duplication, wire-API inference, error classification, plan budgets, capability caching, state round-trip, system-language mapping and bilingual coverage.

**Tooling**

- `scripts/build_app.sh` — assembles and ad-hoc signs `LLMProbe.app` outside the (possibly cloud-synced) checkout, then verifies the signature.
- `scripts/install_cli.sh` — installs the CLI to `/usr/local/bin` with a `~/.local/bin` fallback.
- `scripts/check_privacy.sh` — credential, machine-path and screenshot-metadata gate, wired into `.githooks/pre-commit`.
- `scripts/capture_screenshots.sh` + `scripts/demo_server.py` — reproducible fictional screenshots with metadata stripping.
- `scripts/strip_image_metadata.py` — removes PNG text/EXIF chunks with no image dependency.
- CI: macOS build + self test + unit tests, best-effort Linux CLI build, and the privacy gate.

### Known limitations

- The GUI is macOS-only; Linux has no SwiftUI/AppKit surface.
- Ad-hoc signed builds trip Gatekeeper on first launch; there is no notarisation.
- Windows and Linux have never been run by the maintainer.
- Azure OpenAI needs a deployment-specific URL and is entered manually.

[0.1.0]: https://github.com/Lucas-Qh-Lai/llm-probe/releases/tag/v0.1.0
