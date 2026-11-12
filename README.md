# dsh-fnos

把 DeepSeek Harness（下称 dsh）做成**飞牛 fnOS 原生应用**（fpk）：
应用中心点图标直接进，不碰 Docker，不需要每次去命令行取启动令牌。

```
飞牛桌面 → 点图标 → 192.168.0.x:3080 → 302 → 3081 (dsh Web UI，带本次启动的令牌)
```

## 当前状态

| 项 | 值 |
|---|---|
| 包版本 | **0.9.3（真机 0.9.1 已验收；0.9.2 性能优化、0.9.3 引擎升级，待重打包装机）**。相对 0.7.3 的关键变化：<br>① **0.8.0 多网卡入口（已真机验证）**：dsh 的 CLI 拒绝「通配地址」，只接受某个具体接口的 IP（[HARNESS-ARCHITECTURE §5.1](docs/HARNESS-ARCHITECTURE.md)），所以以前只有被选中的那个地址能进——真机 .109（无线）/ .114（OVS）并存时，从另一个网段点图标就是连接被拒。现在启动时枚举本机 IPv4：dsh 仍绑主地址，其余地址由新增的 `relay` 在 **TCP 层**原样接住（不改 Host、不改字节，WS 与 cookie 都不受影响），并登记进 `--trusted-host`；跳转器改为通配监听、按「请求从哪个地址进来」选 302 目标（白名单校验，防 DNS rebinding）。单网卡机器行为不变。<br>② **0.8.1 Office 技能（已真机验证）**：web 形态默认不挂 `skill-office`，而它的渲染引擎早随 dsh 装进了包里（wasm，约 152MB，一直闲置）。现在用 `--patch` 覆盖层挂上，换来「渲染预览 / 公式重算 / 导出 PDF」，**失败即降级**（三条路径缺一就不传 `--patch`；该覆盖层 0.9.3 起退役，改由上游内置挂载）。<br>③ **0.9.x 引擎跟到 `0.2.2-rc.1`**：封装契约逐项核验无破坏（DEVLOG 37.7），Office 三技能真机实测通过（37.8）<br>④ **0.9.2 性能优化**：node_modules 瘦身（897M→745M、6.9 万→5.4 万个文件）+ Node 24 原生 V8 字节码缓存（冷启动 5-6 秒→4 秒）<br>⑤ **0.9.3 引擎跟到 `0.2.2-rc.2`**：上游重构 Office 链路——web profile 内置挂载 dsh-office-kit + skill-office（4 技能：总纲/docx/pptx/xlsx），0.8.1 的 `--patch` 覆盖层退役；渲染引擎 `libreoffice-kit-wasm`（约 152MB）不再随依赖自动装，由 build.sh 按主包版本补装（`DSH_OFFICE_WASM=0` 可跳过）；CLI 契约不变（DEVLOG 38.1）<br>本地自测 65 通过 / 32 跳过 / 0 失败（Windows；dsh 编排段需 Linux） |
| 上一版验收 | **0.9.1 已在 NAS 真机装成并验收（2026-11-07）**：`probe/05` **54 PASS / 1 WARN / 0 FAIL**、`probe/07` **11 PASS / 0 FAIL**；多网卡转发、Office 三技能、插件安装链、pnpm/npm 转发链全部实测通过（DEVLOG 37.7/37.8） |
| 更早的真机验收 | 0.7.3（2026-11-01）：升级快照改落 `@appshare/dsh/backups`、启动时按 `.modules.yaml` 自动对齐 pnpm store；0.6.7（2026-10-28）：图标、启停入口、「访问权限」页确认 |
| 数据落点 | 共享目录 `dsh/workspace/.dsh-home`（**跨卸载存活**，已实测） |
| 默认工作区 | `dsh/workspace/deepseek-harness/default-workspace`（0.6.6 起自动建；原理见 [ISSUES F22](docs/ISSUES.md)） |
| 任意文件夹当工作区 | 应用设置 →「访问权限」授权目录（读写）→ dsh 里「+ 添加工作区」→ 点首屏的 **「可访问目录」** 选中（0.6.8 起；见 [ISSUES F23](docs/ISSUES.md) / [F24](docs/ISSUES.md)） |
| 多网卡访问 | 0.8.0 起自动：主地址由 dsh 直服，其余本机 IPv4 由 `relay` 接住并加入 `--trusted-host`。手工指定用 `DSH_EXTRA_IPS=192.168.0.109,192.168.0.114`（逗号分隔，排障用） |
| Office 文档 | 0.8.1 起 **渲染预览 / 公式重算 / 导出 PDF** 可用（dsh 自带的 LibreOffice Kit，无需系统装 LibreOffice），0.9.1 真机三技能实测通过（2026-11-07）；0.9.3 起挂载方式由 `--patch` 覆盖层改为上游 web profile 内置（dsh 0.2.2-rc.2）。**生成** docx/xlsx/pptx 需要宿主 Python 库，见 [HARNESS-FEATURES §3.1](docs/HARNESS-FEATURES.md) |
| 运行时 | 自带 Node 24（`v24.22.1`，满足 dsh `engines >=24.9.0`）+ `@deepseek-ai/dsh@0.2.2-rc.2`（0.9.3 起，此前 0.9.0–0.9.2 为 rc.1；钉版理由与升级记录见 [PLAN §3.2](PLAN.md)。注意：文件修改前读取检查与外部修改防护上游默认关闭）。0.9.2 起给 dsh 配 V8 字节码缓存（落 `@appdata/dsh/compile-cache`，随卸载消失，损坏删掉自动重建） |
| 插件 | 0.7.0 起运行时**成套自带 pnpm 10.34.9 + npm 11.21.1**（`runtime/pnpm`、`runtime/npm`，各配 `runtime/node/bin/` 下的 wrapper）。dsh 装插件只 spawn 裸命令 `pnpm`（缺了报 `spawn pnpm ENOENT`，[F28](docs/ISSUES.md)），而 pnpm 的 `view`/`add` 又会把请求转发给裸命令 `npm`（缺了会落到系统那份 10.9.3，被自带 node 24 跑起来就崩，[F29](docs/ISSUES.md)）。插件装进 `.dsh-home` 下的 profile 子目录，**需要能访问 npm registry**（默认 npmmirror），装完重启应用一次才加载 |
| 尺寸 | 包内 `app/` **约 745MB / 5.4 万个文件**（0.9.2 瘦身后实测，瘦身前 897M / 6.9 万）；fnpack 压出的 **`dsh.fpk` 约 216MB**（0.9.x 实测） |
| 已知问题 | 见 [docs/ISSUES.md](docs/ISSUES.md) |

> 侧载包**没有 CLI 升级通道**：`appcenter-cli install-fpk` 对已装应用只回一句 `is installed`。
> 但**界面「手动安装」可以覆盖升级**，不用先卸载（已实测：平台会自己重启进程）。
> 见 [RUNBOOK 4.1](docs/RUNBOOK.md)。

## 文档索引

| 文档 | 读者 | 内容 |
|---|---|---|
| `README.md`（本文） | 所有人 | 项目是什么、现在什么状态、文档怎么找 |
| [docs/DEVLOG.md](docs/DEVLOG.md) | 维护者 | **开发记录**：按时间/版本记改了什么、为什么改、验证结果 |
| [docs/HARNESS-ARCHITECTURE.md](docs/HARNESS-ARCHITECTURE.md) | 维护者 | **上游实现原理**：Cordis 插件树、轮次流程、会话日志、Web 载体与栅栏、沙箱、插件链；以及每条事实对 fpk 封装的硬约束 |
| [docs/HARNESS-FEATURES.md](docs/HARNESS-FEATURES.md) | 维护者 / 用户 | **功能清单**：哪些开箱可用、哪些要开关、哪些在飞牛上不可用（含依据）；以及本轮 Office 适配的做法与边界 |
| [docs/REFERENCE-PROJECTS.md](docs/REFERENCE-PROJECTS.md) | 维护者 | **社区同类项目**：5 个 fpk 封装的技术路线对比、三条被源码推翻的社区经验、采纳/拒绝矩阵、剩余差距 |
| [docs/ISSUES.md](docs/ISSUES.md) | 维护者 / 使用者 | **问题台账**：开头「当前剩余问题（P0–P3）」是**唯一待办来源**；后接平台限制、已修缺陷、待验证项的根因与处置 |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | 维护者 | **上真机清单**：打包 → 手动安装（覆盖升级）→ 验收，逐条可复制 |
| [PLAN.md](PLAN.md) | 维护者 | 技术方案与决策依据（含 fnOS 生命周期、目录布局、运行时选型、安全模型） |
| [fpk/README.md](fpk/README.md) | 使用者 | 安装 / 升级 / 排错的完整步骤 |
| [probe/README.md](probe/README.md) | 使用者 | 真机评估与验收的五个步骤（脚本怎么跑） |
| [docs/FNOS-OFFICIAL-DOCS.md](docs/FNOS-OFFICIAL-DOCS.md) | 维护者 | 官方规范摘录。改 `cmd/`、`config/`、`wizard/` 前先查这份 |

## 目录

```
fpk/                    应用本体（打包成 dsh.fpk）
  manifest              应用元数据：appname=dsh、service_port=3080、桌面入口 dsh.main
  cmd/                  main(start|stop|status|restart|url) + install/config/uninstall 钩子
  app/runtime/          launcher（入口跳转器）、relay（多网卡 TCP 中继）、stub（骨架包占位服务）、node、app（dsh 本体）
  wizard/               安装 / 设置 / 卸载向导（JSON）
  build.sh              在 NAS 上打包：bash build.sh（骨架）/ bash build.sh full（捆绑 dsh）
  selftest.sh           打包前自测：伪造 TRIM_* 环境跑完整生命周期 + 跳转器 HTTP 行为
probe/                  真机脚本：评估、冒烟、安装验收、cookie 持久性
plugin-web-search-ddg/  本地 dsh 插件源码：DuckDuckGo Lite 搜索（零 npm 依赖）
docs/                   开发记录、问题台账、官方规范摘录
scripts/                make-icons.py（生成应用图标，只用标准库，不需要 Pillow）
PLAN.md                 技术方案
```

## 快速开始

**环境要求**

- 飞牛 fnOS（**x86_64 机型**；ARM 装不上，`build.sh` 与平台门禁会双重拦截）；
- 安装位置预留 **≥2GB** 空间（fpk 约 216MB，装完约 750MB，另加数据目录）；
- 无需 Docker、无需 root 操作；浏览器访问 `NAS:3080`（多网卡机器任意网段都行，见「当前状态」①）；
- 打包必须在 NAS 上执行（`fnpack` 是 fnOS 自带）；开发机（Windows/Linux/macOS）只改脚本与跑自测（需 bash、node）。

**打包（只有这一步在命令行，必须在 NAS 上）**

```bash
git clone https://github.com/t366/dsh-fnos.git
cd ~/dsh-fnos/fpk/
bash build.sh full
```

`build.sh` 会先跑 `selftest.sh`，自测不过就中止打包（可用 `DSH_SKIP_SELFTEST=1` 跳过，
但先看清失败项是不是与本次改动无关）。打完自动把 fpk 复制到共享目录 `dsh/workspace`。

**安装 / 升级（全部在飞牛界面里点）**

1. 电脑上：文件管理 → 共享目录 `dsh / workspace` → **先下载 `dsh.fpk`**
2. 应用中心 → 手动安装 → 选刚下载的 fpk（**覆盖升级不用先卸载**，平台会自己重启进程）
   - API Key 留空 = 沿用旧值
   - 入口方式保持默认「点图标直接进入」
3. 只有安装被拒或要回退版本时，才走「卸载（选保留）→ 安装」

**验收（只读）**

```bash
bash ~/dsh-fnos/probe/05-verify-fpk.sh          # 结构 + 入口端到端
bash ~/dsh-fnos/probe/07-cookie-persistence.sh  # 会重启一次应用，验证重启后还能进
```

**功能使用**

日常使用就是浏览器里的 dsh 界面（对话、技能、终端、文件工具都在里面）。使用侧须知：

- 技能与功能的开箱/开关状态：[HARNESS-FEATURES](docs/HARNESS-FEATURES.md)；
- Office 文档预览、公式重算、导出 PDF（0.8.1 起可用，0.9.3 起由上游内置挂载）：见「当前状态」② 与
  [ISSUES「F37」](docs/ISSUES.md)；
- 本地插件（DuckDuckGo 搜索）与 pnpm/npm 转发链：[fpk/README](fpk/README.md)；
- 配置项（API Key、入口方式、可访问目录）在安装/升级向导里改，说明见
  [fpk/README](fpk/README.md)；数据都在共享目录 `dsh/workspace/.dsh-home`，卸载选「保留」即留存。

## 安全边界（必须知道）

`auto` 模式下，**能访问到 `NAS:3080` 的内网设备等于能直接操作 dsh**——它带终端与文件工具。
所以：

- **不要把 3080 映射到公网**；
- 要从外网用，走 VPN / Tailscale，或把「入口方式」改成 `pair`（新设备粘一次令牌，180 天有效）；
- 公网来源不会被自动放行；**带 `X-Forwarded-For` / `X-Real-IP` 等代理头的请求也不会**
  （反代会把来源变成 `127.0.0.1`，只看地址就等于放开）。这条写在代码里，不依赖用户记得。

## 开发约定

- **换行**：`.gitattributes` 已钉 `eol=lf`，Windows 上改完文件不要提交 CRLF；
  `build.sh` 打包前还会把 `cmd/` 等自写文本再清一遍。
- **可执行位**：`cmd/*` 必须有 x 位，`build.sh` 每次都会补；在 Windows 上编辑后别指望它自己保留。
- **版本号**：改 `manifest` 的 `version` 才叫新版本。同版本重装会被应用中心静默跳过。
- **改脚本前先跑本地自测**：`bash fpk/selftest.sh`。Windows 上应为
  **65 通过 / 32 跳过 / 0 失败**（跳过的是权限位、`/proc`、进程组这类 Linux 专属断言，
  以及需要真实 dsh 运行时的软链/降权/dsh 编排段）；Linux 上应全绿
  （Linux 专属跳过项会真跑，数量比 Windows 多十几项）。若在 Windows 上看到共享目录相关的失败，先确认是不是用了旧脚本。
- **权限探测必须切身份**：`log_accessible_paths()` 里所有 `[ -r ]`/`[ -w ]` 都要走
  `probe_as_app`，别图省事直接判 —— 生命周期脚本以 root 跑，root 绕过 mode 位，
  「nobody:0000」的目录会被误判成「读写」，用户照着日志排错只会更迷糊（[ISSUES F25](docs/ISSUES.md)）。
- **`manifest` 里 `disable_authorization_path` 不许改回 `true`**：那会连带把应用设置里的
  「访问权限」整页隐藏，用户再也没法把任意文件夹授权给 dsh，工作区只剩共享目录
  （[ISSUES F23](docs/ISSUES.md)）。
- **不要试图把 `HOME` 挪出 `.dsh-home`**：dsh 的目录选择器从 `homedir()` 起步，家目录在哪儿
  对话框就从哪儿开始；把它指向共享目录会让 dsh 的缓存/凭据/会话散进用户文件区。
  授权目录靠 `$HOME/可访问目录/` 的软链暴露，见 [ISSUES F24](docs/ISSUES.md)。
