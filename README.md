# dsh-fnos

把 DeepSeek Harness（下称 dsh）做成**飞牛 fnOS 原生应用**（fpk）：
应用中心点图标直接进，不碰 Docker，不需要每次去命令行取启动令牌。

```
飞牛桌面 → 点图标 → 192.168.0.x:3080 → 302 → 3081 (dsh Web UI，带本次启动的令牌)
```

## 当前状态

| 项 | 值 |
|---|---|
| 包版本 | **0.6.0**（代码就绪，待打包；真机上装的还是 0.5.0） |
| 最近一次完整真机验收 | **0.5.0 完整包**：`probe/05` **33 PASS / 1 WARN / 0 FAIL**，`probe/07` **10 PASS / 0 FAIL**；监听 `192.168.0.114:3080`，健康检查 `ready=true`。0.6.0 的待验项见 [ISSUES 的 P1/P2](docs/ISSUES.md) |
| 数据落点 | 共享目录 `dsh/workspace/.dsh-home`（**跨卸载存活**，已实测） |
| 运行时 | 自带 Node 24（`v24.22.1`）+ `@deepseek-ai/dsh@0.2.1-rc.3`（钉版理由见 [PLAN §3.2](PLAN.md)） |
| 尺寸 | 包约 990MB；装完实测 **957M / 63056 个文件**（`du -sh /vol1/@appcenter/dsh`，不含软链的 `/var/apps/dsh`） |
| 已知问题 | 见 [docs/ISSUES.md](docs/ISSUES.md) |

> 侧载包**没有 CLI 升级通道**：`appcenter-cli install-fpk` 对已装应用只回一句 `is installed`。
> 升级 = 界面卸载（选保留）+ 界面手动安装。这不是没做，是平台现状，见 [ISSUES P1](docs/ISSUES.md)。

## 文档索引

| 文档 | 读者 | 内容 |
|---|---|---|
| `README.md`（本文） | 所有人 | 项目是什么、现在什么状态、文档怎么找 |
| [docs/DEVLOG.md](docs/DEVLOG.md) | 维护者 | **开发记录**：按时间/版本记改了什么、为什么改、验证结果 |
| [docs/ISSUES.md](docs/ISSUES.md) | 维护者 / 使用者 | **问题台账**：开头「当前剩余问题（P0–P3）」是**唯一待办来源**；后接平台限制、已修缺陷、待验证项的根因与处置 |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | 维护者 | **上真机清单**：打包 → 卸载保留 → 手动安装 → 验收，逐条可复制 |
| [PLAN.md](PLAN.md) | 维护者 | 技术方案与决策依据（含 fnOS 生命周期、目录布局、运行时选型、安全模型） |
| [fpk/README.md](fpk/README.md) | 使用者 | 安装 / 升级 / 排错的完整步骤 |
| [probe/README.md](probe/README.md) | 使用者 | 真机评估与验收的五个步骤（脚本怎么跑） |
| [docs/FNOS-OFFICIAL-DOCS.md](docs/FNOS-OFFICIAL-DOCS.md) | 维护者 | 官方规范摘录。改 `cmd/`、`config/`、`wizard/` 前先查这份 |

## 目录

```
fpk/                    应用本体（打包成 dsh.fpk）
  manifest              应用元数据：appname=dsh、service_port=3080、桌面入口 dsh.main
  cmd/                  main(start|stop|status|restart|url) + install/config/uninstall 钩子
  app/runtime/          launcher（入口跳转器）、stub（骨架包占位服务）、node、app（dsh 本体）
  wizard/               安装 / 设置 / 卸载向导（JSON）
  build.sh              在 NAS 上打包：bash build.sh（骨架）/ bash build.sh full（捆绑 dsh）
  selftest.sh           打包前自测：伪造 TRIM_* 环境跑完整生命周期 + 跳转器 HTTP 行为
probe/                  真机脚本：评估、冒烟、安装验收、cookie 持久性
docs/                   开发记录、问题台账、官方规范摘录
scripts/                make-icons.py（生成应用图标，只用标准库，不需要 Pillow）
PLAN.md                 技术方案
```

## 快速开始

**打包（只有这一步在命令行，必须在 NAS 上）**

```bash
cd ~/dsh-fnos && git pull
cd fpk && bash build.sh full
```

`build.sh` 会先跑 `selftest.sh`，自测不过就中止打包（可用 `DSH_SKIP_SELFTEST=1` 跳过，
但先看清失败项是不是与本次改动无关）。打完自动把 fpk 复制到共享目录 `dsh/workspace`。

**安装 / 升级（全部在飞牛界面里点）**

1. 电脑上：文件管理 → 共享目录 `dsh / workspace` → **先下载 `dsh.fpk`**
   （顺序别反：卸载会把共享目录临时改成 `000`）
2. 应用中心 → dsh → 卸载 → 选「保留会话、凭据与设置」
3. 应用中心 → 手动安装 → 选刚下载的 fpk
   - API Key 留空 = 沿用旧值
   - 入口方式保持默认「点图标直接进入」

**验收（只读）**

```bash
bash ~/dsh-fnos/probe/05-verify-fpk.sh          # 结构 + 入口端到端
bash ~/dsh-fnos/probe/07-cookie-persistence.sh  # 会重启一次应用，验证重启后还能进
```

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
  **29 通过 / 22 跳过 / 0 失败**（22 项是权限位、`/proc`、进程组这类 Linux 专属断言）；
  Linux 上应全绿。若在 Windows 上看到共享目录相关的失败，先确认是不是用了旧脚本。
