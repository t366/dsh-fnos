# DeepSeek Harness 功能清单（以及对飞牛的可移植性）

状态：**v1.0（2026-11-02）**　底本：`deepseek-harness` master `ce7073d`（`0.2.2-alpha.2`）
本包实际运行：`@deepseek-ai/dsh@0.2.1-rc.5`（web 形态）

> 配套文档：[HARNESS-ARCHITECTURE.md](HARNESS-ARCHITECTURE.md)（它讲"为什么只能这么封装"），
> 本文讲"**功能到底有哪些、在飞牛上哪一档**"。

---

## 0. 一句话

dsh 的功能不是"有/没有"，而是三层：

| 层 | 谁会看到 | 例子 |
|---|---|---|
| **形态挂载** | 装好就有 | 会话、工具、沙箱、Web UI |
| **包内但默认关** | 要在「插件」页手动打开 | 会话搜索、自动评审、团队、语音输入… |
| **按需下载** | 打开时才去 npm 装 | Claude Code / Codex 子智能体、Computer use |

飞牛上"功能不可用"的原因，九成不是上游缺能力，而是**我们的形态选的是 `web`**，
以及**宿主缺少某个外部件**（Python 库、浏览器、外部服务）。所以适配的正路是
「用 `--patch` 插一行」，不是改 dsh 源码。

---

## 1. 形态决定功能面（源码依据）

```ts
// packages/util/official-bundles/src/bundles.ts
PROFILE_TEMPLATES = {
  web: { bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'] },
  ...
}
OPTIONAL_BUNDLES  = [ /* 16 个：会话搜索、ralph、终端、徽章技能、会话标题、团队、
                          语音输入、思维链翻译、自动评审、检查器、liveshare、
                          插件市场、worktree、forge、个性化推荐、… */ ]
ON_DEMAND_BUNDLES = [ subagent-claude-code, subagent-codex, cua-bundle ]
```

**关键事实：`base` 里没有 `skill-office`。** 它只出现在
`packages/bundle/sdk-app/cordis.patch.yml`。也就是说 web 形态天然没有 Office 技能，
而它的渲染引擎 `@deepseek-ai/libreoffice-kit` 是 skill-office 的**硬依赖**，
会随 dsh 装进 `node_modules`（Linux 无原生包，走 `libreoffice-kit-wasm`，解包约 152MB）。
**这 152MB 一直在我们包里，但从没被挂载过。**（0.8.1 已修，见 §4）

---

## 2. 功能矩阵

图例：✅ 开箱可用（本包已验证或按设计必然可用）／🟡 有条件可用／⬜ 包内有、默认关／❌ 飞牛上不可用

### A. 核心能力（默认挂载）

| 能力 | 提供者 | 状态 | 说明 |
|---|---|---|---|
| 会话 / 事件日志 / 恢复 | `dsh-session*` | ✅ | `SESSION_FORMAT_VERSION = 4`；升级只需换 runtime |
| Agent 循环 / 计划模式 / 目标 | `dsh-agent-loop`、`plan-mode`、`goal` | ✅ | |
| 读写文件 / 替换编辑 | `dsh-tool-fs`、`fs-patch` | ✅ | |
| 全文搜索 / 文件发现 | `dsh-tool-fs-search` | ✅ | **不需要宿主装 `rg`**：自带打包 worker，走 subprocess 服务 |
| Shell 执行 | `dsh-tool-bash` + `bash-sandbox` | ✅ | 真机 bwrap → landlock 都通过 |
| 子智能体（进程内 / fork） | `dsh-subagent*` | ✅ | 不依赖外部 CLI |
| 工作流（PTC） | `dsh-workflow-ptc` | ✅ | 需要自带 node（已自带） |
| 压缩 / 上下文管理 | `compaction-basic`、`tool-result-pruner` | ✅ | |
| 模型与凭据 | `llm-deepseek-*`、`credentials-local` | ✅ | API key 或账号登录 |
| Web UI / 多端入口 | `dsh-web-app` | ✅ | 令牌 + cookie + 多网卡 relay（0.8.0） |

### B. 本次新开（0.8.1）

| 能力 | 提供者 | 状态 | 说明 |
|---|---|---|---|
| 文档渲染预览 | `skill-office/office-render` | 🟡 | 走 wasm；**依赖宿主字体**，见 §3.3 |
| 公式重算 | `skill-office/office-recalculate` | ✅ | 只重算不自绘，不受字体影响 |
| 导出 PDF | `skill-office/office-export-pdf` | 🟡 | 不需要系统 LibreOffice，但**中文排版同样依赖字体**，见 §3.3 |
| 文档作者（docx/pptx/xlsx） | `skill-office/office-*` | 🟡 | 需要 Python 库；见 §3.1 |

### C. 需要宿主条件的

| 能力 | 依赖什么 | 状态 | 说明 |
|---|---|---|---|
| 插件安装 / 插件市场 | pnpm + npm + registry | 🟡 | F28/F29/F30 已修（自带 pnpm/npm、store 对齐）；**registry 需要 NAS 能出网** |
| 联网搜索 | DeepSeek API | 🟡 | 需要 API key；`web-fetch-http` 直接出网，走系统代理时要注意 `HTTP(S)_PROXY` |
| MCP | 用户自备 server | 🟡 | 协议在包内，server 是用户的事 |
| 定时任务（Schedule） | 进程必须活着 | 🟡 | 见 §3.2：与应用中心 stop 竞争、无崩溃自愈 |
| 附件 / 图片 | 本地磁盘 | ✅ | 落 `$DSH_HOME`，共享目录可跨卸载存活 |

### D. 可选开关（包内有，默认关）

| 能力 | 状态 | 备注 |
|---|---|---|
| 会话搜索 `session-search` | ⬜ | 基于 SQLite 索引，飞牛上应可用，未验 |
| 持久终端 `terminal-bundle` | ⬜ | **不依赖 tmux**（用平台 shell 后端）；web/desktop 默认关且无开关页 |
| 语音输入 `voice-input` | ⬜ | 客户端录音；**http:// 局域网非安全上下文**，可用性未验 |
| 思维链翻译 `cot-translation` | ⬜ | 纯 LLM |
| 自动评审 `auto-review` | ⬜ | 纯 LLM |
| 会话标题（LLM） | ⬜ | 纯 LLM |
| Agent 团队 `agent-team-profile` | ⬜ | 进程内 |
| 检查器 `inspector-profile` | ⬜ | 开发向 |
| worktree `tool-worktree` | ⬜ | 需要宿主 `git` |
| Forge（Git 面板） | ⬜ | 需要宿主 `git ≥ 2.31` 才有"禁用过滤器"的行为 |
| Ralph / 徽章技能 / 个性化推荐 | ⬜ | 纯进程内 |
| 插件市场 `plugin-market-bundle` | ⬜ | 同 §C 的 registry 条件 |

### E. 飞牛上不可用（判断依据明确）

| 能力 | 原因 |
|---|---|
| **Computer use** | 目录里 `platforms: ['darwin']`，只支持 macOS |
| **Liveshare（会话共享）** | 需要单独部署的 Liveshare 服务端 + OAuth；上游文档明确"默认 Web profile 排除它" |
| **browser-use（浏览器操作）** | 上游没有任何 bundle 挂它——它是"部署方自己接一个浏览器 provider"的插槽，我们没有浏览器 |
| **Claude Code / Codex 子智能体** | 按需安装的只是"适配层"，真正要宿主已有对应 CLI；飞牛上没有 |

---

## 3. 两处值得说清楚的边界

### 3.1 Office 作者类技能为什么只到"有条件可用"

`office-docx/SKILL.md` 的默认路径是：
> call `load_workspace_dependencies` and execute the returned Python path with its bundled libraries.
> … If the tool is unavailable, use an already configured environment and report a missing dependency.

而 `load_workspace_dependencies`（`@deepseek-ai/dsh-tool-workspace-dependencies`）**同样只在
sdk-app 形态挂载**，且它的 `source` 必须指向一个自带 Python + site-packages 的 payload 目录
（Desktop 是这么发的）。我们没有这个 payload，所以：

- **能做**：作者类技能会退回"已配置环境"，也就是宿主 `python3` + 库；
- **做不到**：开箱即用。飞牛是否装了 `python-docx` / `openpyxl` / `python-pptx` **尚未验证**；
- `probe/01-preflight.sh` 已加一行报告 `python3` 与这三个库的存在情况，下次上机就能看到。

要彻底解决，得在包里带一个 Python payload（含 lxml 等 C 扩展 → 必须按平台/架构发），
体积约 +60–100MB。**这笔账要不要花，见 §5。**

### 3.2 定时任务与"进程活着"是同一件事

Schedule 是**进程内**实现（Host 自己的 timer），不是 cron。飞牛的约束是：

- 应用中心只轮询 `cmd/main status`，**没有 systemd**；
- dsh 崩了而 launcher 还活着时，`status` 仍返回 0 → 平台不会拉起（T8）；
- 结果：用户设的定时任务会**静默停摆**，直到有人点图标或重启应用。

所以「定时任务」这个功能的可靠性上限，等于 T8 的完成度。这不是 Schedule 的问题，
是我们在 fnOS 上的进程守护缺口。

### 3.3 Linux 走 WASM，而 WASM **只用导入的字体**

`libreoffice-kit` 的 README 写得很直白：

> 原生与 WASM 引擎是按平台筛选的可选依赖。应用构建方必须验证所需引擎已安装：
> **macOS/Windows 使用原生引擎，Linux 使用 WASM。** 必需引擎缺失时，`createConverter()`
> 以 `unavailable` 拒绝。
>
> …WASM **只使用导入的原始文件，找不到可用字体时以 `unavailable` 拒绝**；
> 在最小化容器中转换前请安装字体或配置 `fontDirectories`。

而字体发现默认走"所选操作系统的常规系统/用户路径"，Linux 上就是 `/usr/share/fonts`
与 `~/.fonts` 一类。飞牛是最小化的 Debian，**很可能只有 DejaVu 这类西文字体**。后果分两种：

- 完全没有可用字体 → 转换直接 `unavailable`（报错，但至少不产出坏文件）；
- 有西文字体、缺中文字体 → **PDF 能出，但中文缺字**（`missingFonts` 会报，模型可能不会主动看）。

对我们这种中文场景，第二种更危险：用户拿到一份"能打开但中文是方块"的 PDF。

**为什么这次没顺手把字体塞进包**：字体要落到 `$DSH_HOME/.fonts`（我们的 `HOME` 就是它，
属于用户可写路径），一份 Noto Sans CJK SC 约 16MB。这是「+16MB 换中文 PDF 正确」的交易，
应该先看真机 `/usr/share/fonts` 到底有什么，再决定要不要花——`probe/01` 已加这一行。

---

## 4. 本轮的适配（0.8.1）

| 位置 | 改动 | 作用 |
|---|---|---|
| `fpk/app/runtime/profile/office.patch.yml` | 新增：`- insert:` 一行挂 `skill-office` | 让 web 形态拥有 Office 技能 |
| `fpk/cmd/main` | `office_patch()`：三条路径逐个验存在才传 `--patch` | **失败即降级**，绝不因增强功能拖垮启动 |
| `fpk/build.sh` | 用 dsh 自带的 `yaml` 解析器校验补丁结构；full 模式强制文件存在 | 写错就不出包，而不是装机后打不开 |
| `fpk/probe/05-verify-fpk.sh` | 查资产/Kit 是否存在；查日志里 `office: enabled` | 装机即知"到底挂上没有" |
| `fpk/probe/01-preflight.sh` | 报告 python3、Office 三库、**中文字体** | 为 §3.1 / §3.3 的决策收集事实 |

**为什么不直接改 `profiles/web/cordis.patch.yml`（用户的补丁层）**：
那是用户自己的文件，升级时不该被我们覆盖，也不该塞进用户看不见的东西。
`--patch` 覆盖层是命令行参数，优先级最高、随进程生灭、删掉即恢复原样。

---

## 5. 下一步建议（按性价比）

| 事项 | 成本 | 收益 | 建议 |
|---|---|---|---|
| 上机验证 0.8.1（多网卡 + Office） | 一次安装 | 两条主线的结论落地 | **先做** |
| T8 进程看护（launcher 探活 + 重启 dsh） | 中 | 定时任务、长任务、崩溃恢复**一起**变可靠 | 值得排期 |
| Office 作者类：带 Python payload | 中高（+60–100MB，跨平台矩阵） | 开箱写 Word/Excel/PPT | 先看 probe/01 结果再定 |
| Office 中文导出：带一份 CJK 字体到 `$DSH_HOME/.fonts` | 低（+16MB） | 中文 PDF 不再缺字 | 先看 probe/01 的字体结果；缺就做 |
| 语音输入可用性验证 | 低 | 只影响一个可选功能 | 顺手验 |
| 外网访问（T7 网关） | 中 | DDNS/统一入口 | 按需求定 |
