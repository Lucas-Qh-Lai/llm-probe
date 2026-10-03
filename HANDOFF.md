# LLMProbe 交接文档（给接手的模型）

> 生成时间：2026-10-03 20:14（Asia/Shanghai）
> 工程路径：`~/Documents/编程/LLMProbe`
> 当前版本：0.1.0（未发布，未推送到任何远端）
> 本文档的用途：把"初始需求 / 已完成证据 / 卡住的地方 / 下一步"一次性交给更强的模型继续。

---

## 0. 给接手模型的启动 Prompt（可直接复制）

```
你在 macOS（Apple Silicon）上接手一个已经开发到 80% 的本地工具项目：LLMProbe。

工程路径：~/Documents/编程/LLMProbe
先读这三个文件再动手：
  1) HANDOFF.md（本文件：完整需求 + 现状 + 卡点）
  2) AGENTS.md（本仓库的开发约定与隐私红线，必须遵守）
  3) README.md / README.en.md（对外说明，含功能与 CLI 用法）

设备环境：只有 Command Line Tools，没有 Xcode，不要安装 Xcode。
验证方式一律用 `swift build` + `swift run llmprobe selftest`（不要用 swift test）。

当前状态：引擎 / CLI / macOS GUI 都已实现，32/32 自检通过，隐私门禁通过，
但有一个【未解决的 GUI 窗口 bug】：app 启动后有时永远不出现窗口（进程活着、
NSApp.windows 恒为 0、SwiftUI 从不求值 WindowGroup 的 content 闭包）。
这个 bug 直接阻塞了剩下 3 张 README 截图的拍摄，必须先修。

请按 HANDOFF.md 第 4 节的"还没试过的排查方向"继续，修好后：
  - 跑 scripts/capture_screenshots.sh 补 3 张截图（main-en / discovery / settings）
  - python3 scripts/strip_image_metadata.py docs/images/screenshot-*.png
  - ./scripts/check_privacy.sh 必须 clean
  - 逐张人工看图，确认只有虚构 demo 数据
  - 完成后停下来向用户报告（不要未经确认就 push 到 GitHub）

沟通要求：全程中文；不要拍马屁；每完成一段有意义的工作就汇报进度、证据（命令、数字、路径）和遗留问题；
不确定的、影响面大的动作先问用户；不要在没确认的情况下创建远端仓库或推送。

隐私红线（绝对）：
  - 绝不要把用户本机真实的 base URL / 模型名 / 密钥 / API Key 写进代码、README、截图、commit message 或任何输出。
  - 截图只能来自 scripts/demo_server.py 的虚构数据，且必须走 --state-dir 隔离。
  - 不要动 ~/.cc-switch/、~/.codex/config.toml、CC Switch 进程 / SQLite（只读探测除外）、launchd 与登录项。
  - 不要重启 CC Switch。
  - 不要使用 rm -rf / rm -f；用 find ... -delete 或显式 rm -r。
```

---

## 1. 初始需求（用户原话，勿遗漏）

**核心功能与性能**
1. 检测模型上游工作是否正常，以及模型的输出速度、上下文长度、是否支持工具调用和模态类型。
   - (a) 尽可能支持更多模型的 API 调用，例如 OpenAI、Anthropic、Google 等等。
   - (b) 减少每次测试的 Token 使用量，同时不降低测试的准确度。
   - (c) 能够从 Codex、Claude Code 以及其他 Agent 软件中，自动读取当前的配置文件并加载到软件当中，方便用户测试当前配置的模型是否正常。

**运行与安全**
2. 保持软件完全本地化运行，以减小隐私泄露风险。

**界面与开源**
3. (a) 具有 macOS 原生的 GUI，设计要精美、优雅、现代。(b) 软件必须完全开源。

**跨平台**
4. 可以考虑支持 Windows 或 Linux；用户没有测试条件，README 里必须明确标注"没有测试条件，未经过实际测试"。

**交付要求**
5. 做完开源到 GitHub；README 中英双语两个文件，内有切换按钮，且要带 macOS 界面截图（详细写好）。
6. 自动探测功能必须能探测到 CC Switch 及其相关配置。
7. **隐私红线**：不要把本机真实的模型配置暴露到 GitHub 公网。
8. GUI 版本之外还要有 CLI 版本，方便终端用户或 Agent 调用。
9. 软件本体支持中英文双语，设置里可自由切换。
10. 关于页面加项目 GitHub 链接 + 用户 GitHub 名（`Lucas-Qh-Lai`）+ 一行"喜欢的人可以给我捐助"。
11. 默认语言按系统语言：中文系统→中文，英文系统→英文，**其它语言→英文**。
12. **CLI 只保留英文版本**（GUI 才做双语）。
13. 不需要 Xcode（用户已确认；本机也没有）。
14. 汇报要求：全程中文，比较详细地汇报，不要一直埋头苦干；不要创建长期 git 仓库和 Codex 项目；开发完成并在 GitHub 开源上传后直接终止任务并报告当前目录与状态。

---

## 2. 当前状况（已完成 + 证据）

### 2.1 工程形态

- Swift 6 tools（`swift-tools-version:6.0`），实际工具链 Swift 6.3.2，`swiftLanguageMode(.v5)`，部署目标 `.macOS(.v14)`。
- 三个 target：
  - `LLMProbeCore`：纯 Foundation 的引擎，跨平台（Linux 上可编译 CLI 部分）。
  - `llmprobe`：CLI。
  - `LLMProbeApp`：SwiftUI macOS GUI。
- 顶层文档：`README.md`（中文，约 460 行）、`README.en.md`（英文，约 460 行）、`CHANGELOG.md`、`CONTRIBUTING.md`、`LICENSE`(MIT)、`AGENTS.md`。

### 2.2 功能实现情况

- **5 种协议适配器**：`openai-chat`、`openai-responses`、`anthropic-messages`、`google-gemini`、`ollama-chat`。
- **25 种厂商预设 + custom**（OpenAI / Anthropic / Google / Azure / OpenRouter / DeepSeek / Moonshot / 智谱 / DashScope / SiliconFlow / Groq / Mistral / xAI / Together / Fireworks / Perplexity / Cerebras / Ollama / LM Studio / MLX / vLLM / LiteLLM / One API / Command Code / Custom）。
- **11 个探针**：可达性、模型目录、补全、流式速度（TTFT + tok/s + 多次取中位数）、工具调用、并行工具调用、视觉、结构化输出、上下文窗口、最大输出 token、推理通道、嵌入。
- **三档计划**：`free`（0 completion token，2000 token 预算）/ `quick`（5000）/ `deep`（60000，含 payload 上下文搜索）。
- **错误分类器**：鉴权 / 权限 / 模型不存在 / 请求无效 / 上下文超限 / 限流 / 额度 / 上游 5xx / 超时 / 传输 / 解码，并能从报错文本里提取**真实**上限（例如 `max_tokens is too large: 999999 … supports at most 8192` 取 8192，而不是被拒的 999999）。
- **能力证据分级 + 缓存**：`supported / partial / unsupported / unknown` + 来源（probe / metadata / local config / heuristic），重复测试不重复花 token。
- **自动探测 9 个来源**：CC Switch（`~/.cc-switch/cc-switch.db`，`?mode=ro` **只读** SQLite，覆盖 codex / claude / claude-desktop / gemini / opencode / hermes 六种 app_type）、Codex（自带 MiniTOML，`CODEX_HOME` 感知）、Claude Code、opencode、Gemini CLI、Continue、Aider、环境变量、本机端口扫描（11434/1234/8000/8080/4000/3000/3050/5000）。
- **CLI 子命令**：`discover` / `probe` / `import` / `list-sources` / `selftest` / `version` / `help`，支持 `--json`、退出码 = 最差结论（0 健康 / 1 降级或异常 / 2 用法错误）。
- **GUI**：SwiftUI 侧边栏 + 详情 + 5 张指标卡 + 能力矩阵 + 探针列表 + 自动探测面板 + 端点编辑器 + 速度趋势图（Charts）+ 原生设置窗口（⌘,，含语言 / 数据 / 关于三个 Tab）。
- **关于页面**（本轮新增）：GitHub 仓库链接、作者 `Lucas-Qh-Lai`、GitHub Sponsors 捐助入口、MIT 说明。
- **语言策略**：GUI 双语、设置内即时切换并记住；默认跟随系统（中文→中文、英文→英文、**其它语言→英文**）；**CLI 只输出英文**（脚本 / Agent 匹配的字符串必须稳定）。

### 2.3 验证基线（都是真实跑出来的）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 编译 | `swift build` | `Build complete` |
| 离线自检 | `swift run llmprobe selftest` | **32/32 passed** |
| 隐私门禁 | `./scripts/check_privacy.sh` | `privacy check clean (77 files, mode=tree)` |
| 打包 App | `./scripts/build_app.sh release` | 输出 `signature verified`，安装到 `~/Applications/LLMProbe.app` |
| 签名校验 | `codesign --verify --strict ~/Applications/LLMProbe.app` | 通过（迁移到新路径后重新验证过） |
| CLI 英文化 | 中文系统下 `llmprobe probe …` | 输出全英文（`FAIL Reachability …` / `Verdict: Unhealthy`） |
| Release 包 | `./scripts/package_release.sh` | `dist/LLMProbe-0.1.0.zip`（约 1.0M）+ `.sha256`，解压后签名仍有效 |
| Git | `git log --oneline` | `2dee2cd chore: import LLMProbe 0.1.0 as a local git project` |

### 2.4 截图现状

- 已有：`docs/images/screenshot-main.png`（中文主界面，2582×1750，已剥离元数据，内容是虚构 demo 数据）。
- 已有：`docs/images/AppIcon.png`（1024×1024）、`AppIcon.icns`。
- **缺**：`screenshot-main-en.png`、`screenshot-discovery.png`、`screenshot-settings.png`（README 已经引用这三个文件名，现在链接是断的）。
- 截图流水线：`scripts/capture_screenshots.sh` + `scripts/demo_server.py`（虚构服务，模型名 `demo-small-1` / `demo-reasoner-1` / `demo-large-1`，Base URL `http://127.0.0.1:8899/v1`，端点名 `Acme AI Gateway · …`）。脚本会在 `$TMPDIR` 建隔离 state dir，并在拍完后校验像素宽度、剥离元数据。

### 2.5 本轮（2026-10-03 下午）新做完的事

- 关于页加 GitHub / Sponsors / 作者（`Sources/LLMProbeApp/Views/SettingsView.swift`）。
- 语言解析抽出可测重载 `LanguageSettings.resolve(_:preferredLanguages:)`，新增自检 `localization.follows-the-system-language`（中文 / 英文 / 日文 / 德文 / 韩文 / 空列表 8 组用例）。
- CLI 强制英文：移除 `--language`（CLI 不再接受），新增 `LanguageSettings.pinCommandLineLanguage()` 与自检 `cli.prints-english-only`，自检从 30 项 → 32 项。
- README 中英双文件、CHANGELOG 同步更新（CLI 英文说明、系统语言默认策略、项目地址与支持章节、自检 32 项）。
- 工程从 `~/Documents/Codex/2026-10-03/x20-1-a-api-openai-anthropic/outputs/llm-probe` 迁移到 `~/Documents/编程/LLMProbe`，并在此建立本地 Git 工程。

---

## 3. 卡住的地方（重点：GUI 窗口 bug）

### 3.1 用户最初的现象

> "怎么老是这个程序打开一会儿，一两秒又秒关？是不是程序本体有 bug？"

### 3.2 已确认并已修掉的原因（"秒关"的元凶）

**签名失效被系统 SIGKILL。**
- 证据：`~/Library/Logs/DiagnosticReports/LLMProbe-2026-10-03-165512/165516/165531.ips`，三份都是
  `reason: Taskgated Invalid Signature`、`signal: SIGKILL (Code Signature Invalid)`。
- 原因：App bundle 曾直接在**云同步目录**里组装，文件提供者（iCloud/文件同步）给 bundle 加了扩展属性，导致 ad-hoc 签名失效；macOS 在启动后 1–2 秒把它杀掉 —— 与"打开一两秒就关"完全吻合。
- 修法（已落地）：`scripts/build_app.sh` 在 `$TMPDIR` 里组装 + ad-hoc 签名 + 校验，再 `ditto` 到 `~/Applications`。迁移到新路径后再次验证：`codesign --verify --strict` 通过、无 xattr、16:55 之后**没有新的崩溃报告**。
- 结论：用户看到的"秒关"= 这一类，已解决。

### 3.3 仍然存在、尚未解决的 bug：**窗口有时永远不出现**

**症状**：进程活着、不崩、Dock 有图标 / 或者根本看不到窗口；`NSApp.windows.count` 恒为 0；永远不出现窗口。

**已取得的硬证据**：

1. 直接启动并打开窗口追踪：
   ```
   LLM_PROBE_WINDOW_DEBUG=1 LLM_PROBE_DEBUG_LOG=/tmp/win.log \
     open -n ~/Applications/LLMProbe.app --args --state-dir /tmp/x --autorun --language zh
   ```
   输出（连续 9 秒）：
   ```
   WINTRACE +0.000s launch, windows=0
   WINTRACE +1.001s tick windows[0]
   …
   WINTRACE +9.001s tick windows[0]
   ```
   对照：不带 `--autorun` 时同一命令立刻 `launch, windows=1`，窗口 1291×875 正常。
2. 临时插桩（在 `LLMProbeAppMain.init`、`AppModel.init` 起止、WindowGroup content 闭包各写一条日志）结果是：
   `AppMain.init` ✅ 执行、`AppModel.init begin/end` ✅ 执行完，**WindowGroup 的 content 闭包从未被求值**。
   → 也就是 SwiftUI 根本没有实例化这个 scene，不是我们视图内部卡住、也不是网络请求卡住。
3. 主线程 / Runloop 是健康的：追踪用的 1 秒 `Timer` 一直在跳，`DispatchQueue.main.asyncAfter` 的窗口 pin（0.35/0.9/1.6/2.6/4/6/8 秒）也都在执行。
4. 最小复现对照：另建一个 20 行的 SwiftUI app（`WindowGroup` + `NSApplicationDelegateAdaptor`，放在 `/tmp/minswift/Tiny.app`），用同样的"裸 flag"argv 启动，**每次都有窗口**。
   → 说明这不是 SwiftUI 的普遍行为，问题出在本工程 / 本 app 的某个状态上。
5. 触发条件目前**没有稳定规律**：先测到 `--autorun` 3/3 失败、不带 flag 2/2 成功；后来不带 flag 也出现失败。
   即：**间歇性、与进程/系统状态相关**，不是简单的参数问题。
6. 影响面：`scripts/capture_screenshots.sh` 用的是
   `open -n LLMProbe.app --args --state-dir <demo> [--autorun|--demo-discovery|--show-settings] --language <zh|en>`，
   最近一次运行 5 次尝试全部报 `no window appeared`，所以**剩下 3 张截图现在拍不出来**。

**已经排除掉的原因（都实测过，别再重复）**：
- 不是崩溃：进程一直活着，runloop 正常，无新的 `.ips` 崩溃报告。
- 不是我们自己的 argv 解析：`--foobar`（我们的解析器完全忽略的裸 flag）也能复现；`LaunchOptions` 有无该 flag 解析结果完全一致。
- 不是 `UserDefaults` argumentDomain：三种 argv 下 dump 出来的 domain 内容都一样（只有 `-state-dir`、`-language`）。
- 不是缺少 / 损坏的 Saved Application State：本机 `~/Library/Saved Application State` 目录根本不存在。
- 不是窗口 frame 恢复成非法值：`defaults read dev.llmprobe.app` 里 `NSWindow Frame SwiftUI.WindowGroup<…>` = `221 74 1291 875 0 0 1512 949`，是合法的屏内位置。
- 不是没激活：`AppDelegate.pinMainWindow()` 在没有 `canBecomeMain` 窗口时会调 `NSRunningApplication.current.activate(options: [.activateAllWindows])` + `NSApp.activate(ignoringOtherApps: true)`，实测这 7 次 pin 都执行了，窗口依然不出现。

**还没试过的排查方向（建议按顺序做）**：
1. 状态持久化假设：`defaults delete dev.llmprobe.app` 后立刻启动，看是否恢复；再试 `open … --args -ApplePersistenceIgnoreState YES`；必要时 `defaults write dev.llmprobe.app NSQuitAlwaysKeepsWindows -bool NO`。
   （注：上一次尝试这条实验时用户打断了，`defaults` **没有被删**，还在原样状态，可以直接做。）
2. 收集系统日志：失败那次启动后 `log show --last 2m --predicate 'process == "LLMProbe"'`（之前用 `--style compact` 没抓到东西，可以试试 `--info --debug`，或 `--predicate 'senderImagePath CONTAINS "SwiftUI"'`）。
3. LaunchServices 竞态：把"上一次实例退出"到"新实例启动"之间的等待拉长（例如 15 秒），并对比 `lsregister -dump | grep dev.llmprobe` 的状态；也可以试 `lsregister -kill -r -domain local -domain system -domain user` 前先备份（这一步影响面大，**先问用户**）。
4. 代码级兜底（推荐，无论根因是否查清）：把 `WindowGroup` 换成 `Window`，或在 `AppDelegate` 里做"最后手段"——启动 N 秒后如果仍然没有任何 `canBecomeMain` 窗口，就用 `NSWindow` + `NSHostingController(rootView: ContentView().environmentObject(model))` 自己创建并显示一个原生窗口。这样即使 SwiftUI 拒绝实例化 scene，用户也一定看得到窗口。
   注意：`AppModel` 目前由 `App` 的 `@StateObject` 持有，做手动窗口时需要把它提升成可共享的单例 / 由 AppDelegate 持有，避免出现两份状态。
5. 换账号 / 重新登录后再测（排除 per-session 的残留状态）。
6. 复现统计脚本：同一组参数连跑 20 次，记录成功/失败，找出真正的相关变量（现在样本太少，容易误判）。

### 3.4 其它已知但影响较小的问题

- `swift build` 有两条警告：`Sources/LLMProbeApp/Support/AppModel.swift:209` 的 `[SendableClosureCaptures]`（在 Swift 6 语言模式下会变成错误），以及 `ProbeEngine.swift` 附近一条 "no 'async' operations occur within 'await' expression"。都不影响当前构建，但发布前值得清掉。
- `AppDelegate` 里保留了 `LLM_PROBE_WINDOW_DEBUG` / `LLM_PROBE_DEBUG_LOG` 追踪代码（无害，专门为查这个 bug 留的，建议修好后再决定是否删除）。
- 迁移后 `.build` 缓存被清过一次（旧路径的绝对路径被烤进 module cache，会报 `missing required module 'SwiftShims'`），所以现在需要重新构建；`docs/`、`dist/`、`.build/` 里 `dist` 与 `.build` 都被 `.gitignore` 排除，`dist/LLMProbe-0.1.0.zip` 仍在本地磁盘上（未提交）。

---

## 4. 剩余工作清单

1. **修窗口 bug**（第 3.3 节）。
2. **补 3 张截图**：`main-en` / `discovery` / `settings`；之后必须
   `python3 scripts/strip_image_metadata.py docs/images/screenshot-*.png` → `./scripts/check_privacy.sh` → 逐张人工看图确认只有虚构数据。
3. **推送 GitHub**（需要用户确认仓库名与 Public/Private；`gh` 已登录 `Lucas-Qh-Lai`，仓库名先前查过 `llm-probe` 未被占用）。
4. **发 Release `v0.1.0`**：附 `dist/LLMProbe-0.1.0.zip` 与 `.sha256`；release 累积，不要删旧版 / 旧 tag。
5. （可选）清理上面的编译警告；确认 README 里的截图链接都能渲染。

---

## 5. 环境与操作注意事项（踩过的坑）

- **没有 Xcode**：`swift test` / XCTest 不可用，用 `swift run llmprobe selftest` 代替（32 项）。不要在没问用户的情况下装 Xcode。
- **不要在云同步目录里直接组装 App bundle**：会让 ad-hoc 签名失效、被 taskgated 杀掉。必须走 `scripts/build_app.sh`（在 `$TMPDIR` 组装 + 签名 + `ditto` 到 `~/Applications`）。
- 迁移 / 复制工程目录后，`.build` 会因绝对路径失效：`find .build -depth -delete` 后重新 `swift build`。
- macOS 没有 GNU `timeout`；`du` 不支持 `--exclude`。
- 不要在项目里直接 `rm -rf` / `rm -f`（用户硬规则）。
- 截图前如果锁屏，会拿到错的窗口几何：脚本会检查，失败就等解锁。
- Stage Manager 会把非活动 App 的窗口缩成缩略图：脚本靠"校验截图像素宽度 + 重试"兜底；本次失败与 Stage Manager 无关（是窗口真的不存在）。
- 用户在这台机器上有一个正在运行的 CC Switch（端口 3050 等）：**只读探测可以，绝不重启、绝不写它的库**。

---

## 6. 隐私红线（再强调一次）

以下内容**永远不能**出现在代码、README、截图、commit、Release 说明或聊天输出里：

- 用户本机真实的 base URL、模型 ID、厂商名组合、任何 key / token / cookie。
- 状态文件 `~/Library/Application Support/LLMProbe/state.json`（当前含用户真实配置探测结果，只在本机）；CC Switch 数据库内容同理（只读引用，不复制）。
- 截图只能来自 `scripts/demo_server.py` 的虚构数据（`Acme AI Gateway · demo-*` / `127.0.0.1:8899`）。

`scripts/check_privacy.sh` 是自动化门禁，已接进 `.githooks/pre-commit`（本仓库已 `git config core.hooksPath .githooks`）。它现在会自动检查：凭据样式字符串、机器路径、截图的 XMP/EXIF 元数据。

---

## 7. 关键文件地图

```
LLMProbe/
├── AGENTS.md                    仓库开发约定（用户自己维护，别重写）
├── HANDOFF.md                   本文件
├── README.md / README.en.md     中英双语说明（含截图引用、CLI 用法、厂商表、隐私说明）
├── CHANGELOG.md / CONTRIBUTING.md / LICENSE(MIT)
├── Package.swift                3 个 target 的清单
├── Sources/
│   ├── LLMProbeCore/            引擎：Model / Net / Probes / Providers / Discovery / Support
│   │   ├── Discovery/CCSwitchReader.swift   ← CC Switch 只读 SQLite 读取
│   │   ├── Discovery/CodexConfigReader.swift
│   │   ├── Probes/ProbeEngine.swift          ← 11 个探针与三档计划
│   │   └── Support/SelfTest.swift            ← 32 项离线自检
│   ├── llmprobe/main.swift      CLI 入口（英文输出，子命令解析）
│   └── LLMProbeApp/             SwiftUI GUI
│       ├── AppMain.swift                    ← WindowGroup / Settings scene（窗口 bug 相关）
│       ├── Support/AppDelegate.swift        ← 窗口 pin、重开处理、窗口追踪
│       ├── Support/AppModel.swift           ← 唯一状态源（@MainActor ObservableObject）
│       ├── Support/LaunchOptions.swift      ← --state-dir / --autorun / --language 等
│       └── Views/                           ← ContentView / Sidebar / EndpointDetail / SettingsView …
├── scripts/
│   ├── build_app.sh              组装 + ad-hoc 签名 + 安装（必须用它）
│   ├── capture_screenshots.sh    虚构数据截图流水线（含重试与像素校验）
│   ├── demo_server.py            离线虚构上游（OpenAI 兼容）
│   ├── strip_image_metadata.py   PNG 元数据剥离
│   ├── check_privacy.sh          隐私门禁
│   ├── package_release.sh        zip + sha256
│   ├── install_cli.sh            安装 CLI 到 /usr/local/bin（回退 ~/.local/bin）
│   └── window_id.swift           取窗口 id / 尺寸（供截图与排查用）
├── docs/images/                  AppIcon + 截图（目前只有中文主界面那一张）
├── Tests/LLMProbeCoreTests/      XCTest（需要 Xcode，本机跑不了，CI 里跑）
└── .github/workflows/ci.yml      macOS 构建 + 自检；Linux 尽力而为构建；隐私门禁
```

---

## 8. 本次任务的元信息（给接手者了解上下文）

- 这是一次"长链路自主任务"，用户要求：少问问题、自主推进、阶段性详细汇报。
- 用户的硬规则（写在仓库 `AGENTS.md` 与全局约定里）：**未经确认不动本机配置 / 不推送远端**、**不确定就停下来报告**、**不要 `rm -rf`**、**评价要客观不要拍马屁**。
- 用户已明确：**不要创建长期 Codex 项目**；本次迁移后本地 Git 工程已经建好（`2dee2cd`），远端推送需要再次确认。
- 迁移前的旧目录 `~/Documents/Codex/2026-10-03/x20-1-a-api-openai-anthropic/` 现在只剩空的 `outputs/` 与 `work/`，没有工作文件；是否删除由用户决定。
- `~/Library/Logs/DiagnosticReports/LLMProbe-2026-10-03-1655*.ips` 三份旧崩溃报告是"秒关"的原始证据，暂不清理。
- `~/Applications/LLMProbe.app` 是从本工程构建并安装的 GUI 副本（已签名有效），排查窗口 bug 时可以直接用它启动。
