# Contributing

Thanks for taking a look. This is a small, focused tool: it probes LLM upstreams, locally, with as few tokens as possible. Contributions that respect those three constraints are welcome.

## Ground rules

1. **Nothing leaves the machine.** No telemetry, analytics, crash reporting, update checks or "anonymous usage" of any kind. The only outbound requests are the probes the user asked for.
2. **Read-only on other tools.** Readers may read `~/.cc-switch`, `~/.codex`, `~/.claude`, `~/.config/opencode` and friends. They must never write there. CC Switch's SQLite stays `?mode=ro`.
3. **Never print a credential.** Every string that leaves the process goes through `Redactor`. Report "configured / not configured", never the value.
4. **Token discipline is a feature.** A new probe must justify its cost, must have an entry in `ProbeKind` with a token estimate, and must not run in the `free` plan unless it spends zero completion tokens.
5. **Bilingual.** Every user-facing string carries both languages at the call site — `L10n.t(_ zh: String, _ en: String)`, or `L10n.pick(zh:en:)` — so there is no `.strings` bundle to silently miss a key. `llmprobe selftest` fails when an enum loses a translation.

## Getting set up

```bash
git clone https://github.com/Lucas-Qh-Lai/llm-probe.git
cd llm-probe
swift build
swift run llmprobe selftest      # must be 100% green before and after your change
```

Xcode is optional: the Command Line Tools are enough for `swift build` and the built-in self test. `swift test` needs a full Xcode install.

## Before you open a pull request

- [ ] `swift build` is clean (warnings that already exist are fine; new ones are not).
- [ ] `swift run llmprobe selftest` reports every check passing — add a check when you add behaviour.
- [ ] `./scripts/check_privacy.sh` is clean.
- [ ] If your change touches the UI, run `./scripts/build_app.sh release` and look at the real app.
- [ ] If you add a probe or a vendor, update both READMEs and `CHANGELOG.md`.

## Testing without spending money

`scripts/demo_server.py` is an offline OpenAI-compatible server with fictional models. It is the intended way to develop probes:

```bash
python3 scripts/demo_server.py --port 8899 &
./.build/debug/llmprobe probe --url http://127.0.0.1:8899/v1 --model demo-small-1 --plan quick
```

Never commit real endpoints, model ids from a private gateway, or credentials — including inside screenshots. `check_privacy.sh` scans for all of that, and it also rejects PNG capture metadata.

## Adding a vendor

1. Add the case to `ProviderKind` (`Sources/LLMProbeCore/Model/WireAPI.swift`) with its display name, default base URL, common environment variable names and likely wire API.
2. Add the Chinese name in `Sources/LLMProbeCore/Support/Localization.swift`.
3. Extend the inference table in `Sources/LLMProbeCore/Providers/EndpointResolver.swift` if the hostname is distinctive.
4. Run the self test — enum coverage is enforced, so a missing translation or default fails the run.

## Adding a wire API

A new protocol means a new adapter in `Sources/LLMProbeCore/Providers/`: request encoding, response decoding, streaming deltas, tool-call shape, and the error extracts the classifier needs (context limit, output limit). Keep vendor-specific quirks inside the adapter — the probes should not learn about vendors.

## Reporting bugs

Include the version (`llmprobe version`), macOS version, the wire API and vendor involved, and the exact command. **Redact** your base URL, model id and any key before pasting output; the CLI redacts secrets, but a hostname can still identify a private gateway.

## License

By contributing you agree your work is released under the [MIT License](LICENSE).
