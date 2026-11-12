# 问题台账

记录这个项目踩到的坑：哪些是**平台限制**（改不了，只能绕）、哪些是**我们自己的缺陷**（已修）、
哪些**还没验证**。新问题按 `P*/F*/T*` 续编号，修完不要删条目——留着的价值在于「下次别再查一遍」。

状态口径：

| 状态 | 含义 |
|---|---|
| 🚫 平台限制 | fnOS 侧行为，改不了；已在代码/流程里绕开 |
| ✅ 已修 | 根因清楚、有提交、有验证手段 |
| ⚠️ 待验证 | 代码写了，真机没跑过；**不要当成已完成** |
| 📋 待办 | 明确要做但还没做 |

## 总表

| 编号 | 问题 | 类别 | 状态 | 处置位置 |
|---|---|---|---|---|
| P1 | `install-fpk` 对已装应用静默跳过 | 平台 | 🚫 | 流程：界面卸载+手动安装 |
| P2 | CLI `uninstall` 拒绝手动安装的应用 | 平台 | 🚫 | 流程：只能 Web UI 卸载 |
| P3 | `install-local` 触发缺陷 10237 | 平台 | 🚫 | 不用 `install-local` |
| P4 | fnpack 打包时重写 manifest | 平台 | 🚫 | `probe/05` 键名归一化 |
| P5 | 安装后 `config/`、`wizard/` 变 644 | 平台 | 🚫 | `build.sh` 钉 755，探针告警 |
| P6 | 卸载清空 `@appdata` 内容、`@appshare` 变 000 | 平台 | 🚫 | 0.2.0 起数据放共享目录 |
| F1 | `status` 返回 3 但进程实际在跑 | 缺陷 | ✅ | `cmd/main` `is_running()` |
| F2 | 令牌抓到上一轮的旧值 | 缺陷 | ✅ | `cmd/main` 只读本次新增日志 |
| F3 | 进程秒退却报「启动成功」 | 缺陷 | ✅ | `cmd/main` 端口通后再 `kill -0` |
| F4 | 自测沙箱 cwd 落到真实安装目录 | 缺陷 | ✅ | `selftest.sh` 传 `TRIM_DATA_SHARE_PATHS` |
| F5 | 配对只认裸 token，粘整条 URL 报 400 | 缺陷 | ✅ | `launcher/server.mjs` `extractToken` |
| F6 | Windows 上 Linux 专属断言假失败 | 缺陷 | ✅ | `selftest.sh` `check_linux` |
| F7 | 自测报 000：假上游还没监听 | 缺陷（测试） | ✅ | `selftest.sh` `wait_up()` + 重试 |
| F8 | 自测报 000：Location 残留 `\r` | 缺陷（测试） | ✅ | `hloc()`/`getloc()` 改 `tr -d '\r'` |
| F9 | `auto` 把反代来源误判成内网直连 | 缺陷（安全） | ✅ | `launcher` `viaProxy()`；`selftest` 加回归 |
| F10 | token 字符集写死，含 `.` 就被截断 | 缺陷 | ✅ | `cmd/main` + `launcher` + probe 统一放宽 |
| F11 | purge 在共享目录 000 时静默失败 | 缺陷 | ✅ | `uninstall_callback` `force_rm()` + 失败告知 |
| F12 | 同版本打包只警告，装上去是空操作 | 缺陷 | ✅ | `build.sh` 默认阻断，`DSH_ALLOW_SAME_VERSION=1` 放行 |
| F13 | 开发机上 selftest 大面积假失败 | 缺陷（测试） | ✅ | `selftest.sh` `cygpath -u` + 自动取 PATH 的 node |
| F14 | 残留运行时让自测「骨架阶段」变成 dsh 阶段 | 缺陷（测试） | ✅ | `selftest.sh` 沙箱内移除 `runtime/app` + 断言模式 |
| F15 | 旧版留下的配对密钥 700 永不自愈 | 缺陷 | ✅ | `launcher` `loadSecret()` 读到即收紧为 600 |
| F16 | 以 root 跑探针把 dsh-home 写成 root 所有 | 缺陷（探针） | ✅ | `probe/07` `run_main()` 降权 + 重启后自检 |
| F17 | 入口只绑局域网地址，平台探测不到「在跑」 | 缺陷 | ✅ | `launcher` 回环双绑（0.6.0 真机首验，0.9.1 probe/07 11 PASS）；按钮问题由 T10 结案，见「F17」 |
| F18 | stop 报成功但进程还活着 → start 只回 10330 | 缺陷 | ✅ | `cmd/main` `is_alive()` 复核 + 失败上报 |
| F20 | 版本守卫与包落点只认 `/var/apps/<app>`，会双双失效 | 缺陷（构建） | ✅ | `build.sh` 三处探测 + 落点加 `@appshare` + 打印 `cp` |
| F21 | 图标在应用中心发虚，四轮才找到根因 | 缺陷（视觉） | ✅ | 根因是拿官网 favicon(50×50 细线条) 当图标；0.6.5 原样改用官方 `icon-512.png`，用户实测「好很多」 |
| F22 | 没有默认工作区：`xdg-user-dir` 回显 `$HOME`，dsh 判「文档目录不可用」 | 缺陷（启动） | ⚠️ | `cmd/main` `ensure_documents_dir()` + `ensure_default_workspace()`；**待装 0.6.7 验证** |
| F23 | 应用设置里没有「访问权限」，任意文件夹都加不成工作区 | 缺陷（权限） | ✅ | `manifest` `disable_authorization_path=false` + `cmd/main` `log_accessible_paths()`；真机 0.6.7 已出现「访问权限」页并成功授权 |
| F24 | 「选择工作区目录」只列 `.dsh-home`，退不到 `/vol1`，看不到刚授权的文件夹 | 缺陷（导航） | ⚠️ | `cmd/main` `link_accessible_paths()`：授权目录软链进 `$HOME/可访问目录/`；**待装 0.6.8 验证** |
| F25 | `auth-paths:` 用 root 身份探测，日志写「读写」而 dsh 实际读不了 | 缺陷（假阳性） | ⚠️ | `cmd/main` `probe_as_app()` 切到应用用户 + `sample_unreadable()` 抽查子项；**待装 0.6.8 验证** |
| F26 | Web 端附件上传全灭：卷目录 000 撞上 dsh 的 fsync-to-root | 缺陷（权限） | ✅ | `chown dsh:dsh` + `chmod o+rx /vol1 /vol1/@appshare`；见正文 |
| F27 | agent 会话环境三连坑：工作区不可写 / 工具 schema 误导 / 沙箱只读 | 缺陷（环境） | ⚠️ | 坑 1 已结案（走 dsh 授权通道）；坑 2/3 属工具与平台 |
| F28 | 「添加插件」一律失败：运行时只有 node 二进制，没有 pnpm | 缺陷（打包） | ✅ | 0.6.9：`build.sh` 装 pnpm 10.34.9 + `cmd/main` 前置 PATH；真机已消除 `spawn pnpm ENOENT` |
| F29 | 插件信息仍读不出来：pnpm 把 `view` 转发给系统 npm 10.9.3，和自带 node 24 不兼容 | 缺陷（打包/依赖链） | ✅ | 0.7.0：运行时成套带 npm 11.21.1 + 打包时真跑 `pnpm view` 当门禁；**0.7.1 真机已能读出包描述与 `版本 0.9.26`** |
| F30 | 插件安装报 `ERR_PNPM_UNEXPECTED_STORE`：profile 的 node_modules 由别的 store 装出来 | 缺陷（依赖/环境） | ✅ | 0.7.2 手工写 `store-dir` 后 `pnpm store path` 已回旧 store；0.7.3 起 `cmd/main` 每次启动按 `.modules.yaml` 自动对齐——2026-11-01 19:18 实测走「沿用已有配置」分支（`/vol1/@appshare/dsh/.pnpm-store`）；「自动写入」分支待干净机器 |
| F31 | 升级前的数据快照一次都没跑过：备份的是 0.2.0 之前的老路径，`[ -d ]` 恒假静默跳过 | 缺陷（升级） | ✅ | 0.7.2 真机已验证：`backup: ok …pre-upgrade-0.7.1-to-0.7.2-20261101-183329.tar.gz (486M)`，`tar -tzf` 首行 `.dsh-home/` |
| F32 | 凭据检查永远 `credentials: absent`：同一个失效路径，让「不用重新登录」这条验收无法证伪 | 缺陷（判据） | ✅ | 0.7.2 真机已验证：`home: /vol1/@appshare/dsh/workspace/.dsh-home` + `credentials: kept`（同日 16:10 / 17:05 两次旧版升级仍是 `absent`，构成对照） |
| F35 | 升级快照落在 `@appdata/dsh/backups`，而卸载会清空该目录内容（P6）：真要回滚就得卸载重装，快照先被卸载删掉 | 缺陷（恢复路径） | ✅ | 0.7.3 真机已验证：`backup-dir: /vol1/@appshare/dsh/backups`，新包 486M 落位，且 0.7.2 那份旧包已同卷 `mv` 过来（mtime 仍是 18:33，证明未重打包）；卸载存活性沿用 P6 实测 |
| F33 | 启动日志明文写入完整登录令牌（`"token":"…"` 未打码），而 info.log 正是外发排障的那份 | 缺陷（安全） | ✅ | 0.7.2：`start: state=` 两条正则都打码；2026-11-01 18:33 之后的行实测 **0 命中**；`dsh web:` 那行控制不了，改由 RUNBOOK 强制脱敏 |
| F34 | 手工启动算出第二个 var 目录 → 两套 pidfile → 3080 被占 2h20m | 缺陷（路径） | ✅ | 0.7.2：`PKGVAR` 缺省值按 `@appcenter → @appdata` 归一 |
| F36 | `build.sh` 的 `chmod +x cmd/*` 会把 `cmd/lib-home`、`cmd/*.mjs` 加成 755，仓库记的是 644 → 打过包的机器 `git pull` 被「本地改动会被覆盖」挡住 | 缺陷（构建） | ✅ | 0.7.3：`chmod +x cmd/*` 之后对这两类显式 `chmod a-x`；详见 DEVLOG 31.5 |
| F37 | Web 形态没有 Office 技能：`skill-office` 只在 sdk 形态挂载，而它的渲染引擎（wasm，约 152MB）早就随 dsh 装进了包，白躺着 | 缺陷（形态选择） | ✅ 0.9.1 真机验证 | `cmd/main` 用 `--patch` 挂 `skill-office`，三路径缺一即降级；37.7 enabled + 37.8 三技能实测；见「F37」 |
| T1 | 0.5.0 打包与真机安装 | — | ✅ | `probe/05` 33 PASS / 1 WARN / 0 FAIL |
| T2 | cookie 跨重启 / 令牌是否一次性 | — | ✅ | `probe/07` 10 PASS：令牌可复用、cookie 跨重启存活 |
| T3 | 端口写死 3080，不可配置 | — | 🚫 不做 | 见「T3 为什么不做」：端口是打包期常量 |
| T4 | 升级不可降级，schema 兼容未验证 | — | 📋 | 见 PLAN §7.6 |
| T5 | 解包瞬间磁盘峰值未测（耗时与占用已测） | — | ⚠️ | 下次安装时轮询 `df` |
| T6 | 双网卡（.109 无线 / .114 OVS）只有一个能进 | — | ✅ 0.9.1 真机验证 | `relay` + `--trusted-host` + 跳转器白名单；37.7 实测 .109→.114 转发，见「T6 多网卡」 |
| T7 | 未接飞牛统一网关，外网/DDNS 无解 | — | 📋 | **判断已修正**：dsh 支持挂载前缀，缺的只是 unix-socket 反代层 |
| T8 | 无进程看护，dsh 崩了不会自动拉起 | — | 📋 | 见下文 |
| T9 | 上游 `0.2.2` 线发布进度 | — | ✅ 0.9.0 跟到 rc.1 | 见「T9 版本跟随」：0.2.2 转 rc 且 latest 指向它，2026-11-07 跟到 `0.2.2-rc.1` |
| T10 | 应用中心没有「停用」入口 | — | ✅ | 在「打开」右侧 ▼ 下拉里，非缺陷 |
| T11 | UI 手动安装更高版本时，是覆盖升级还是静默跳过 | — | ✅ | 0.6.0 实测覆盖成功，见下文 |
| T12 | 只出 `x86` 包，ARM 机型装不上 | — | ⚠️ 门禁已加 | 构建期校验架构，见「T12 双架构」 |
| T13 | dsh 的「安全上下文」API 在局域网 HTTP 下是否可用 | — | ✅ 已核 | 上游 0.2.x 已用 `getRandomValues` 替代，见 [REFERENCE-PROJECTS §3.3](REFERENCE-PROJECTS.md) |
| T14 | dsh Web UI：控制流拒收 >10000 字符文本导致 composer 崩溃，外加两处 404 | 上游行为 | ⚠️ 待复现定位 | 见「T14 Web UI 控制流 10000 字符上限」；非 fpk 封装层缺陷 |

---

## 剩余问题总览

> 截至 2026-11-07，真机为 **`0.9.1`**（引擎 `0.2.2-rc.1`，功能实测全绿）；**`0.9.2`（运行时瘦身 + V8 字节码缓存）已提交，待下次重打包覆盖安装**。
> 这里只列**还没关掉的**，按「下一步要不要动手」分四档：
> **A 档**一条命令能关、**B 档**要改代码（已定方案待排期）、**C 档**证据已在手可直接结案、
> **D 档**明知有风险但决定先不动。已修缺陷见第二节，平台限制见第一节，历史验收见第三节。
>
> **最近动作**（2026-11-07）：0.9.1 装机验收通过（probe/05 54 PASS / 1 WARN / 0 FAIL、probe/07 11 PASS / 0 FAIL）；
> T6（多网卡）、F37（Office 技能）真机结案；0.9.2 性能优化（app 运行时 897M→745M、冷启动 5-6 秒→4 秒）待打包装机；
> T3 结案为「不做」（端口是打包期常量）；T7 判断修正（dsh 支持挂载前缀，缺的是 unix-socket 反代层）；
> T14（2026-11-04 记）：dsh 控制流 10000 字符拒收致 composer 崩溃，待新会话复现定位。

### 0.7.3 装机验收（2026-11-01 19:18）

```console
$ ls -lh /vol1/@appshare/dsh/backups/
-rwx------ 1 dsh dsh 486M Nov  1 18:33 pre-upgrade-0.7.1-to-0.7.2-20261101-183329.tar.gz
-rwx------ 1 dsh dsh 486M Nov  1 19:18 pre-upgrade-0.7.2-to-0.7.3-20261101-191752.tar.gz
```

| 项 | 实测 | 结论 |
|---|---|---|
| 落点 | `backup-dir: /vol1/@appshare/dsh/backups（数据目录 /vol1/@appshare/dsh/workspace/.dsh-home）` | ✅ |
| 新快照 | `backup: ok …/pre-upgrade-0.7.2-to-0.7.3-20261101-191752.tar.gz (486M)` | ✅ |
| 旧快照迁移 | 0.7.2 那份出现在新目录，**mtime 仍是 18:33** —— 同卷 `mv` 而非重新打包 | ✅ |
| store 自愈 | `pnpm-store: 沿用已有配置 /vol1/@appshare/dsh/.pnpm-store` | ✅ 走分支 1（用户已配，不覆盖）；「自动写入」分支待一台干净机器 |

两个坑记一下，下次别重踩：

1. 迁移那行的日志前缀是 `upgrade_init: backup: 迁移旧快照 …`。用
   `grep 'upgrade_init: (backup-dir|迁移旧快照)'` 会**漏掉**它——不是没迁，是模式写窄了；
   正确写法是 `grep 'upgrade_init: backup'`。
2. 旧目录 `@appdata/dsh/backups` 迁移后变空，`rmdir` 会顺手删掉；若里面还有别的文件，
   目录会留下（无害，但别误判成「没迁移」）。

### A 档　差一条命令（F33 / F30 已在此档关掉，剩两条）

| 项 | 判据 | 现状 / 缺什么 |
|---|---|---|
| **F25 探测身份** | 造一个 `700 root` 的目录加进授权列表，`grep '读不了' info.log` 应出现该目录，且不再写「读写」 | 现有 25 条 `auth-paths` **全是（读写）**，假阳性那条分支从没被触发过 |
| **F34 var 归一** | 停应用后 `bash /var/apps/dsh/cmd/main start`：`/vol1/@appdata/dsh/dsh.pid` 在、`/var/apps/dsh/var/dsh.pid` 不在 | 可选；手工启动属风险操作，要顺手确认再停一次能停干净 |

### B 档　要改代码（方案已定，等排期）

| 项 | 工作量 | 不做的后果 |
|---|---|---|
| ~~**T6 双网卡**~~ | **0.8.0 已实现，0.9.1 真机验证通过**：`relay` + `--trusted-host` + 跳转器白名单 | 已结案，见「T6 多网卡」 |
| **瘦身** 977MB（fpk 199MB）→ 约 120MB | 中：`install_dep_apps: nodejs_v24` + 去 bundled node | 安装慢、占用翻倍 |
| **插件能力** | 中：`bin/dsh` 包装 + 官方 plugin market bundle | 「一切皆插件」用不起来，只能一个个手装 |
| **T8 进程看护** | 中：先理清与应用中心 stop 的竞争 | dsh 崩了不会自愈 |
| **T3 端口可配** | 小-中：manifest / 向导 / UI / 跳转器四处联动 | 3080 撞车只能卸载重装 |
| **T7 统一网关** | 大：`microApp` + `app.sock` 反代 + `auto` 判据重写 | 外网 / DDNS / FN Connect 无解；但做了能一次带走 T6 |
| **ARM 包** | 中：交叉构建 + 真机验证 | 覆盖不到 ARM 机型 |

**排序上的一个判断（2026-11-02 更新）**：T6 已经做了，而且**不会**被 T7 推翻——
两者是不同层：T6 解决"局域网内从哪张网卡进来都能用"，T7 解决"从飞牛域名/外网进来"。
T7 落地后，launcher 应改成只监听 `127.0.0.1`（由网关转发），那时 relay 可以整段关掉
（一个开关的事），不需要重写网卡探测。所以现在的顺序是：T6 已上线并观察真机，
T7 先把 unix-socket 反代层做出来，再决定入口是否切到网关。

### C 档　证据已在手，更新台账即可结案

`info.log`（807 行，10-27 17:32 → 11-01 17:15，26 次启动）里已能反证这四项，缺的只是走一遍 UI：

| 项 | 日志证据 |
|---|---|
| ~~**F17 回环双绑**~~ | 19 次 `launcher: listening on http://127.0.0.1:3080 (loopback, 供平台与本机自检)`；已结案（按钮问题由 T10 收口，双绑 0.9.1 probe/07 持续验证） |
| **F22 默认工作区** | 14 次 `default-ws`：1 次 `created df888b19-…` + 13 次 `skip: 已有默认工作区` —— 只建一次、之后不动 |
| **F24 授权目录导航** | 22 次 `access-links: 挂载 Project -> /vol1/1000/Project`；两次手工启动正确走「无授权目录，保持现状」，软链没被误删 |
| **F27 坑 1（工作区不可写）** | 走 dsh 授权通道后可写，已结案 |

剩下要人眼看的只有一处：dsh 里「+ 添加工作区 → 可访问目录」能不能点到 `Project`。

### D 档　明知有风险，暂不动

| 项 | 为什么先不动 |
|---|---|
| **T4 升级不可降级** | 要验「旧 dsh 读不读得动新 schema」，只能拿真实数据赌一次；收益是理论上的 |
| **T5 解包峰值** | 已知耗时与占用，只是没测瞬时峰值；下次安装顺手轮询 `df` 即可，不值得专门跑一轮 |

> **另有 8 项长期实测不在本表**，只在 [PLAN §10.2 / §10.3](../PLAN.md) 维护：pty 实例化、
> `.114` 地址稳定性、`run-as` 真实沙箱档位、`settings.conf` 重写时机、`ui/config` 端口不一致、
> `install_dep_apps` 是否被接受、`nodejs_v24` 被升级时的行为、`/usr/local/bin/node` 的来历。
> 它们不挡当前任何一步，所以不在两处重复维护。

### 已关闭记录：P0 实例归属（判据留用）

root 残留与平台拉起的实例在 HTTP 层完全一样（`3080/healthz` 200、`3081` 401 两者都会给），
所以判据只能是**端口属主 + pidfile + PID 世代**：

```bash
ss -ltnp | grep -E ':308[01]'
ps -o user=,args= -p "$(cut -d' ' -f1 /var/apps/dsh/var/dsh.pid)" 2>/dev/null || echo "无 pidfile"
```

2026-10-27 23:37 实测正常：pidfile 在、属主 `dsh`、命令行含 `--port 3081`，
PID 已换成新一轮（`3359xxx`，root 那批是 `3280xxx`）。
处置步骤见 [RUNBOOK「EADDRINUSE 3080」](RUNBOOK.md)；
**别用 root 手工 `cmd/main start` 应急**，那正是这条链的起点。

---

## 一、平台限制

### P1 `install-fpk` 对已装应用静默跳过

```console
$ appcenter-cli install-fpk ./dsh.fpk
is installed
```

只回这一句，`target/` 不更新、`upgrade_init/callback` 不执行。`install-fpk --help` 只有
`-e/--env`、`-v/--volume`，**没有 force / upgrade**；界面上也没有「重新安装」。

**影响**：没有命令行升级路径，`upgrade_*` 钩子永远走不到。

**处置**：升级固定为「界面卸载（保留数据）→ 界面手动安装」。`build.sh` 打完会比对
「包版本 vs 已装版本」，相同时直接 `die`（F12），避免又白装一次。

### P2 CLI `uninstall` 拒绝手动安装的应用

```console
$ appcenter-cli uninstall dsh
Failed to uninstall dsh, please uninstall it from Web UI.
```

`uninstall` 没有任何 flag。**后果**：所有卸载实验都必须有人在界面上点，脚本无法自动化。

> 这个坑在 `probe/06-upgrade-truth.sh` 上真实发生过一次假阳性：卸载被拒、脚本却继续判
> 「数据全存活」。现在该脚本加了门禁——**没看见 `/var/apps/dsh` 消失就判实验无效**。

### P3 `install-local` 触发平台缺陷 10237

```console
fork/exec /tmp/appcenter.pack./cmd/install_init: permission denied  (code 10237)
```

`install-local` 是「先卸载再安装」，临时解包目录被 chown 后**丢了目录的 x 位**，导致钩子
无法执行，装到一半失败。**不要用它做升级**。

### P4 fnpack 打包时重写 manifest

打包后 manifest 从 649B 变成 942B，键值被对齐补空格：

```ini
version                    = 0.1.0
```

原本 `grep -E '^service_port='` 这种写法会**静默取空**，探针因此误报过「三处端口不一致」。

**处置**：读 manifest 一律先归一化键名（去掉引号/空格）再比，见 `probe/05-verify-fpk.sh` 的 `mval()`。

### P5 安装后 `config/`、`wizard/` 变 644

安装器 chown 时把文件的可执行位抹掉了（与 P3 同源）。目前**不影响功能**（这些文件由平台读取，
不直接执行），但每次 `05` 探针都会 WARN。

`build.sh` 会把目录钉成 755；如果你的改动需要这些文件可执行，别指望安装后还留着。

### P6 卸载会清空 `@appdata` 内容

界面卸载选「保留」时的实测结果：

| 路径 | 结果 |
|---|---|
| `@appconf` | 保留 |
| `@apphome`、`@appmeta` | 目录在 |
| **`@appdata`** | **目录在，但内容被清空**（`dsh-home` 被删） |
| `@appcenter`、`@apptemp` | 删除 |
| `@appshare` | 目录被 `chmod 000`，**但内部文件全部存活** |

这就是 0.2.0 把 `dsh-home` 与配置副本搬到共享目录 `.dsh-home` 的唯一原因。不要把它搬回去。

---

## 二、已修缺陷

### F1 `status` 返回 3 但进程实际在跑

**现象**：应用中心显示「已停止」，实际 `3080` 在听。

**根因**：`is_running()` 用字符串比对进程命令行，软链路径与真实路径写法不同 → 匹配失败。

**修法**：`readlink -f` 展开后，四种路径写法任一命中即认定在跑。`selftest.sh` 加了
「经软链路径调 status 仍 = 0」的回归项。

### F2 令牌抓到上一轮的旧值

**现象**：点图标被送到 dsh 的 401 页。

**根因**：`cmd/main` 用 `grep` 扫**整个** `info.log`，命中上一次启动留下的、已失效的 token。

**修法**：启动前记日志长度，只从 `tail -c +N` 的新增部分抓；抓到后写 `dsh-url.txt` 与
`launcher.json`（均 600）。

### F3 进程秒退却报「启动成功」

**现象**：`start` 回 0，端口其实没人听。

**修法**：等端口可连之后**再** `kill -0 $pid` 校验；失败时打印占用该端口的进程，便于定位。

### F4 自测沙箱 cwd 落到真实安装目录

**现象**：`selftest.sh` 在开发机上把工作目录指到了真实安装路径。

**根因**：沙箱没传 `TRIM_DATA_SHARE_PATHS`，`main` 找不到 `shares/` 就退回了默认路径。

**修法**：自测显式传 `TRIM_DATA_SHARE_PATHS`，并加 `cwd=` 断言。

### F5 配对只认裸 token

**现象**：用户粘贴整条 `http://…/?token=…` 报 400。

**修法**：`extractToken()` 先匹配 `token=`，再回退裸 token（`{16,}`）。

### F6 Windows 上 Linux 专属断言假失败

**修法**：`check_linux` + `uname -s` 判定，dsh 专项段整段 SKIP。Windows 上稳定
「27 通过 / 22 跳过 / 0 失败」属正常。

### F7 自测 000：假上游还没监听

**现象**：NAS 上 `FAIL auto：上游接受这条令牌（303）（期望 303，实际 000）`，
诊断显示端口在 `LISTEN`、上游日志 `up ready`。

**根因**：自测里的假 dsh 是独立 node 进程，第一发 `curl` 撞在它 `listen()` 之前的窗口，
连接被拒 → `000`（curl exit 7）。

**修法**：`wait_up()` 轮询到真返回 303 再开始断言；断言失败重试 2 次；失败时打印
LOC / curl 报错 / 上游日志 / 端口监听。提交 `9adb7be`。

> 这一条**不是产品缺陷**。判断依据：同段里 `pair：正确令牌 → 302` 通过，而那条要求
> 跳转器自己去请求同一个上游。

### F8 自测 000：`Location` 残留 `\r`

**现象**：修完 F7 仍然 000，且重试三次都失败。

**根因**：解析用了 `sed -nE 's/^[Ll]ocation: *(.*[^ ]) *\r?$/\1/p'`。
GNU sed（开发机）认 `\r` 这个转义；**fnOS 自带的 sed 不认**，把它当字面 `r`，
于是行尾的 `\r` 被 `[^ ]` 一起捕获。

后果是**静默的 000**：

```console
$ curl -s -o /dev/null -w '%{http_code}' "http://…/?token=A"$'\r'
000            # exit 3，加 -s 时连 "URL rejected" 报错都看不到
```

浏览器容忍 `\r`，所以「把地址粘进浏览器能进、脚本却 000」这种矛盾现象就是这么来的。

**修法**：取头不依赖 sed 转义——先 `tr -d '\r'`，再用 bash 裁尾随空白
（`[[:space:]]` 含 CR，第二道保险）。三处：`fpk/selftest.sh` 的 `hloc()`、
`probe/05` 与 `probe/07` 的 `getloc()`（07 原先会因此误判「重启后进不去」）。
提交 `cfd363c`，来龙去脉见 [PLAN §5.1.1](../PLAN.md)。

### F9 `auto` 把反代来源误判成内网直连（安全）

**现象**：`auto` 模式下，只要 `socket.remoteAddress` 是私网就自动 `302` 带令牌进入。
反代（nginx / frp / 将来的飞牛统一网关）会把 remoteAddress 变成 `127.0.0.1`，
于是**公网访客也被放行**——README 原先写的「公网来源不会被自动放行」在套了反代之后不成立，
而 dsh 自带终端与文件工具。

**修法**：`launcher/server.mjs` 新增 `viaProxy(req)`，看到
`X-Forwarded-For` / `X-Forwarded-Host` / `X-Forwarded-Proto` / `X-Real-IP` /
`Forwarded` / `CF-Connecting-IP` / `True-Client-IP` 任一个，就不再相信 remoteAddress，
一律落到配对页。`selftest.sh` 增加「带 X-Forwarded-For 不自动跳转」的回归项。

**为什么不是直接拒绝**：能拿到令牌的人仍然可以配对进入；这里只收回「自动放行」这一层。
接入统一网关后应改成校验网关身份头（T7），而不是简单放开。

### F10 token 字符集写死，含 `.` 就被截断

**现象**：`cmd/main`、`launcher`、`probe/*` 都用 `[A-Za-z0-9_-]+` 抓 token。
上游若把令牌换成带 `.` / `+` / `%` / `=` 的 opaque 串，抓到的只是前半段：
入口仍然 `302`，但点进去 401，而日志里的 token 已打码，很难看出是被截断。

**修法**：统一改成「只排除分隔符与空白」——shell 用
`grep -oE 'token=[^&"[:space:]]+' | cut -d= -f2-`，JS 用 `[^&\s]+`（含 `decodeURIComponent`）；
`extractToken` 的裸 token 白名单放宽到 `[A-Za-z0-9._~+%=-]{8,512}`。
端到端验证：token 为 `abc.def-ghi_jkl` 时 `Location` 完整、上游回 303。

### F11 purge 在共享目录 000 时静默失败

**现象**：卸载选「全部删除」时，`rm -rf "$SHARE_HOME" 2>/dev/null`。
但卸载流程会把共享目录临时改成 `000`（P6 实测），删除失败且没有任何提示，
重装后旧会话与 API Key 又被 `install_callback` 恢复回来——「全部删除」成了谎话。

**修法**：`uninstall_callback` 新增 `force_rm()`：先 `chmod u+rwx` 父目录、
`chmod -R u+rwX` 目标，再删；删完用 `[ -e ]` 复核。失败时写 `TRIM_TEMP_LOGFILE`
明确告知用户手动删除，不再假装成功。

### F12 同版本打包只警告

**现象**：`build.sh` 发现包版本 = 已安装版本时只打印一段警告，仍然继续打包。
装上去时应用中心回一句 `is installed`，`target/` 不更新，白折腾一轮。

**修法**：默认 `die`；确实要做同版本对照实验时显式 `DSH_ALLOW_SAME_VERSION=1`。

### F13 开发机上 selftest 大面积假失败

**现象**：Windows 上直接 `bash fpk/selftest.sh` 得到 22 通过 / 7 失败，而不是文档说的全绿。
失败集中在共享目录与启动：`dsh-home 在共享目录里`、`start 退出码`、`Key 写入副本` 等。

**根因**（两条，都与产品逻辑无关）：
1. Git Bash 的 `TMPDIR` 是 `C:\Users\...`，而 `TRIM_DATA_SHARE_PATHS` 用 `:` 分隔多路径，
   盘符里的冒号把共享目录切成 `C` → `install_callback` 判定「没有共享目录」；
2. `find_node()` 只认 bundled 运行时与 fnOS 的 `nodejs_v24`，不查 PATH，
   开发机上 stub 也起不来。

**修法**：`selftest.sh` 启动时用 `cygpath -u` 把 `ROOT` 转成 `/c/...`（无冒号），
非 Linux 上自动取 `command -v node` 作为 `DSH_TEST_NODE`。
实测：**29 通过 / 22 跳过 / 0 失败**，与 NAS 语义一致。
**注意**：跳过项仍是 Linux 专属断言（权限位、`/proc`、进程组），Windows 上的绿灯
不代表这些项也验过。

### F14 残留运行时让自测「骨架阶段」变成 dsh 阶段

**现象**（2026-10-27，NAS 上首次跑到 Linux 全量断言）：

```console
== HTTP 探测
  FAIL  GET / 返回 200（期望 200，实际 302）
  PASS  GET /healthz 正常
通过 54 / 跳过 0 / 失败 1
```

看着像入口跳转器坏了，实际是**这一段根本没有按骨架模式跑**。

**根因**：`detect_mode()` 只判断 `runtime/app/node_modules/@deepseek-ai/dsh/package.json`
存不存在。源码树里残留着上一次 `build.sh full` 装出来的运行时（`app/runtime/app` 与
`app/runtime/node`），而这两个目录在 `.gitignore` 里——**`git pull` 不会替你清理**。
于是沙箱副本带着 dsh 包，第一阶段被判成 dsh 模式：

1. 跳转器占住 `service_port`（13080），dsh 退到 13081；
2. `GET 13080/` 得到 302，而这一段断言是按骨架模式写的「应 200」；
3. 下一段「模拟 dsh 模式」会用自己的假 dsh 覆盖 `package.json`，所以它反而全绿，
   失败只出现在中间那一段，更容易误判。

**日志里的铁证**：dsh 模式段打印的运行时路径是沙箱内的
`target/runtime/node/bin/node`。若没有残留，`find_node()` 只会找到系统的
`/var/apps/nodejs_v24/...`——出现沙箱路径就说明副本里有 bundled 运行时。

**修法**（`selftest.sh`）：
1. 复制 `app/` 进沙箱后，立刻 `rm -rf "$ROOT/target/runtime/app"`（只删副本，
   源码树不动；`build.sh` 第 4 步会自己重建），并打印一行提示；
2. 新增断言「本段跑的是骨架模式」（grep `start: mode=stub`），把模式错位与
   HTTP 故障区分开——以后再遇到，失败项会直接说「模式不对」，不用再顺着 302 反推。

**验证**：在开发机上人为放置一份残留 `runtime/app` 后跑自测，输出
「沙箱内已移除残留的 dsh 运行时」，随后 `本段跑的是骨架模式`、`GET / 返回 200` 均 PASS，
**30 通过 / 22 跳过 / 0 失败**；移除残留后再跑，结果相同。
NAS 上预期 `58 通过 / 0 跳过 / 0 失败`（原 55 项 + 模式断言 + 双绑 2 项）。

### F15 旧版留下的配对密钥 700 永不自愈

**现象**：0.5.0 装机后 `probe/05` 报 `WARN 配对密钥权限是 700（建议 600）`。

**根因**：`launcher` 只在**新建**密钥时设权限：

```js
fs.writeFileSync(SECRET_FILE, ..., { mode: 0o600 });
fs.chmodSync(SECRET_FILE, 0o600);
```

而 `loadSecret()` 一旦读到已有文件就直接返回，**不再收紧权限**。所以早期版本用 700 创建的那个
文件会一直跟着走，跨升级也不修——即使当前代码写出来必然是 600。

**影响**：低。`@appdata` 本身只有应用用户可写，700 的实际暴露面与 600 差别不大；
但它会让每次 `probe/05` 都挂一条 WARN，久了就没人看 WARN 了。

**修法**：读到时顺手自愈——权限不是 `600` 就 `chmod 600`（失败忽略）。

**0.6.0 实测：修了，但没修对（2026-10-28 00:11）**。装了 0.6.0 之后 `probe/05` **仍然**报
`WARN 配对密钥权限是 700`。根因不是权限环境，是自愈条件写错了：

```js
if ((fs.statSync(SECRET_FILE).mode & 0o077) !== 0) ...   // 旧
```

`0o077` 只覆盖 group/other 位，而 `0o700` 的 group/other **恰好都是 0**，条件恒假，
所以「读到旧密钥就收紧」这段代码对 700 从来没执行过：

```
0o700 & 0o077 = 0       → !== 0 为假 → 不修（bug）
0o644 & 0o077 = 0o044   → 真       → 修
```

**0.6.1 修法**：整段比对 `(mode & 0o777) !== 0o600`。四种典型值实测：

| mode | 旧判断 | 新判断 |
|---|---|---|
| 700 | 不动（bug） | 收紧到 600 |
| 600 | 不动 | 不动 |
| 644 | 收紧 | 收紧 |
| 777 | 收紧 | 收紧 |

教训：**用位掩码做「不等于某值」的判断时，掩码必须覆盖全部有效位**。这里想表达的是
「权限不等于 600」，却写成了「group/other 有任何权限」，两者在 700 上分道扬镳。

### F16 以 root 跑探针会把 dsh-home 写成 root 所有

**现象**：`probe/07` 会 `stop` + `start` 一次。若像 2026-10-27 那样以 `root` 直接跑，
dsh 也以 root 启动，于是 `dsh-home` 里新生成了 root 所有的 `-wal` / 会话库。

**后果**：应用中心以 `dsh`(971) 启动时对这些文件没有写权限（目录是 `dsh:971 700`，
但里面混了 `root:root` 的文件），轻则「会话少了」，重则 SQLite 打不开、dsh 起不来。
而且这类故障不会报错，只会表现为「数据不见了」。

**修法**：`probe/07` 增加 `run_main()`：当 `id -u = 0` 时用
`su -s /bin/sh -c "'$ROOT/cmd/main' start" dsh` 降权执行，与 `run-as: package` 对齐；
并在重启后 `find "$HOMEDIR" -user root` 自检，命中就报 FAIL 并给出 `chown` 命令。

**已受影响的机器**：本机 2026-10-27 那次 `probe/07` 是 root 跑的，
需要一次性 `chown -R dsh:AppUsers /vol1/@appshare/dsh/workspace/.dsh-home`。
**已于 23:41 执行完毕，复查 root 文件数 = 0。** 以后只跑 `probe/07` 不会再产生（`run_main()` 已降权）。

### F17 入口只绑局域网地址，平台/本地自检连不上回环

**现象**：应用中心卡片只有「打开 / 卸载」，没有停止。但安装后的 manifest 里
`ctl_stop = true`、`cmd/main status` 返回 0、`service_port = 3080` 三处一致——
也就是说「不可启停」这条官方语义**并不成立**，问题在别处。

**推断的根因**：launcher 只 `listen(PORT, HOST)`，而 `HOST` 是自动探测到的局域网地址
（`192.168.0.114`）。回环上没有监听，于是：

- 平台对 `service_port` 的本地探测（`127.0.0.1:3080`）是 ECONNREFUSED；
- 任何本机命令 `curl http://127.0.0.1:3080/healthz` 也不通（这个坑在 README 里
  已经踩过一次，当时只改了文档，没改根因）。

平台拿不到「在跑」的证据，就按未运行渲染，启停入口随之消失。

**修法**：`launcher` 在 `--host` 不是回环时，**额外**在 `127.0.0.1` 上起一个监听，
共用同一个 handler。局域网访问不受影响；回环监听失败只记日志，不阻止启动
（不能为了一个本地检查把入口整个起不来）。

**验证**：自测新增两条断言（用 `127.0.0.2` 冒充非回环地址）——「给 LAN 地址时回环也监听」
与「原地址仍可访问」，Windows 上 `32 通过 / 22 跳过 / 0 失败`。

**真机结果（2026-10-28 00:09，0.6.0）——双绑本身成功，但推断被证伪**：

```
loop=200                 ← 127.0.0.1:3080 已通
lan=200
LISTEN 127.0.0.1:3080    users:(("MainThread",pid=3369574))
LISTEN 192.168.0.114:3080 users:(("MainThread",pid=3369574))   ← 同一个进程两个监听
appcenter-cli status dsh → running, rc=0
```

三项都成立，应用中心**依旧没有停用入口**。所以「平台靠回环探测判断运行」这条推断**不成立**，
F17 作为修复手段保留（回环可达本身有价值：本机自检、`probe` 脚本、以后接网关），
但它不再被当作按钮问题的根因。**T10 后于 0.6.x 结案**：入口在「打开」右侧 ▼ 下拉里，非缺陷。
双绑本身持续在真机验证（0.6.0 首验，0.9.1 probe/07 11 PASS / FAIL 0）。

### F18 stop 报成功，其实进程还活着 → start 只会回 10330

**现象**（2026-10-27，真机）：

```
appcenter-cli stop dsh                  → [Info] stop success
appcenter-cli start dsh                 → [Error] code 10330
ls /var/apps/dsh/var/dsh.pid            → No such file
```

**根因**：`do_stopf()` 用 `kill -TERM/-KILL` 结束进程，但**不检查结果**。
应用用户（`dsh`）杀不掉 root 起的进程（EPERM），`kill` 静默失败，
脚本却照样 `rm -f` pidfile 并 `log "... done"`、`return 0`。于是：

1. 平台认为应用已停止；2. `status` 因为 pidfile 没了也报「未运行」；
3. 下一次 `start` 时 3080/3081 仍被那个 root 进程占着，新进程 EADDRINUSE 退出；
4. 平台只把「启动失败」映射成错误码 **10330**，对话框里没有任何原因。

这三个状态（pidfile 没了、status 说没运行、端口还被占）是排查时最难受的组合，
而它是由我们自己的 stop 造出来的。

**为什么会有 root 进程**：F16——`probe/07` 曾以 root 跑过一次 `start`。
先把进程起来、再让应用用户去停，就必然踩到这个点。

**修法**：

- `do_stopf()` 收尾用 `is_alive()`（排除僵尸态 `Z`）复核；仍活着就 `log FAILED`、
  把「停止失败：xxx 仍在运行，当前身份 yyy 没有权限」写进 `TRIM_TEMP_LOGFILE`、
  **保留 pidfile**、`return 1`；
- `do_stop()` 汇总子调用的结果，非 0 时**不再删 `launcher.json`**；
- `stop` 子命令 `exit $?`，让 `appcenter-cli stop` 能如实报错；
- `start` 的 EADDRINUSE 文案补一句「若占用者是别人（如 root 手工启动）留下的，
  先用那个身份停掉它，否则应用中心只会给一个 10330」。

**修不了的**：平台把失败统一成 10330，我们无法改变它的错误码，
只能保证原因写进它展示的那段文字（`TRIM_TEMP_LOGFILE`）与 `info.log`。

### F20 「已装版本」与「共享目录」只探 `/var/apps/<app>`，会双双失效

**现象**（2026-10-27 23:44，0.6.0 打包日志）：

```
== 版本 ==
包：dsh 0.6.0    已安装：<无>
...
== 就绪（前端安装用）==
没找到共享目录（应用还没装？），包留在 /root/dsh-fnos/fpk/./dsh.fpk
```

可同一时刻应用明明在跑（23:56 复测：`3080/healthz` → 200、`3080/` → 302、`3081/` → 401）。

**根因**：两个检查都写死 `/var/apps/<app>`——那是平台给应用挂的**软链入口**
（`target -> /vol1/@appcenter/dsh`、`shares/workspace -> /vol1/@appshare/dsh/workspace`）。
实测这层入口并非一直存在（应用在跑、目录却没了），于是：

1. **版本守卫（F12）静默失效**：读不到已装版本 → `INST_VER` 为空 → 同版本也能打出来，
   装上去是空操作。这正是 F12 想拦的那种白装一趟；
2. **包落到 `/root/dsh-fnos/fpk/`**：那里文件管理看不到，界面「手动安装」选不到包，
   等于把「打完就能装」的体验砍掉。

**修法**（`build.sh`）：

- 已装版本按 `①/var/apps/<app>` → `②/vol1/@appcenter/<app>` → `③/vol1/@appmeta/<app>`
  依次找，命中即用，并把**读自哪个路径**打出来；
- 三处都没有、但 `appcenter-cli check` 说「is installed」时，**明确警告「本次版本守卫无法生效」**，
  不再让守卫悄悄空转；
- 落点候选把 `/vol1/@appshare/<app>/workspace`（共享目录实体，卸载保留数据后仍在）排在最前，
  `/var/apps/<app>/shares/workspace` 退为备选；
- 全都找不到时，直接打印可复制的 `cp` 命令，而不是只说一句「包留在某处」。

**教训**：只要路径里出现 `/var/apps/<app>`，就要想到它是**平台生成的软链**，不能当稳定前提。
同类踩点已有 F14（`.gitignore` 的构建产物不随 `git pull` 消失）——都是「按某个路径/目录存在
与否判断状态」的假设失效。


### F21 应用中心图标发虚，四轮才找到根因 ✅

**现象**：

1. 0.6.0：自绘 `>_` 几何图（占位性质）；
2. 换成 DeepSeek 蓝鲸后（0.6.1），用户反馈「分辨率低，有点糊」；
3. 0.6.2 把入口图标从 64px 源换成 256px 源（文件名不变），用户装完反馈**「还是很糊」**。

**诊断**：详情页图标显示位置约 **56 CSS px**。0.6.2 之后 `target/ui/images/icon_64.png`
已是 256×256 源，除非屏幕 DPR > 4，像素量都不该是瓶颈。所以问题不在像素数，在**观感**：

| 因素 | 白底蓝鲸（0.6.1/0.6.2） | 后果 |
|---|---|---|
| 底色 | 白色 + 应用中心卡片底色 `#f5f6f8` | 圆角边界融进背景，整体发虚 |
| 主体色 | `#4D6BFE` 浅蓝，与白底对比约 3.5:1 | 边缘不够实 |
| 细节 | 眼睛约 2px、腹部镂空、尾鳍分叉 | 56px 下塌成灰噪点 |

换句话说：**对比度不足 + 细节过密，看起来和分辨率不足一模一样**，靠加像素永远修不好。

**修法**（0.6.3）：

- 深蓝底 `#4D6BFE` 圆角 + **白色剪影**，全图只有两层，对比度约 6:1；
- 主体占画布 **88%**（256 档）/ **94%**（64 档），把像素预算全给轮廓；
- `probe/05` 新增两条断言：① 入口图标按 `ui/config` 的 `icon` 字段**实际声明**去查（不再写死
  `icon_64.png`）；② 读 PNG 头拿真实像素尺寸，读到 64 就 WARN —— 那意味着安装器做了降采样，
  属于平台行为，只能靠设计补救。

**0.6.3 装包后的实测结论（2026-10-28 00:46，截图量测）**：

新设计已经生效（界面上确实是蓝底白鲸），所以**缓存和设计都排除掉了**。剩下的只能是
「喂给渲染器的源分辨率」。逐一排查：

| 候选文件 | 尺寸 | 若平台读它，96px 显示是否清晰 |
|---|---|---|
| `ui/images/icon_64.png` | 256×256 | 清晰 |
| `ui/images/icon_256.png` | 256×256 | 清晰 |
| `ICON_256.PNG` | 256×256 | 清晰 |
| `ICON.PNG` | **64×64** | **糊** ← 唯一能解释现象的 |

界面上那个图标约 96 物理像素宽，和 64 拉到 96 的 1.5 倍拉伸特征吻合。
**结论：详情页读的是包根 `ICON.PNG`**，而它按官方规范一直是 64×64。
前两轮改的是 `ui/images/` 下那两张，等于全打在空处。

**社区横向参照（2026-10-28 用 GitHub API 逐个量出来的）**：

| 同款项目 | 星 | `ICON.PNG` | `ICON_256.PNG` | 配色 |
|---|---|---|---|---|
| `yuexps/deepseek.harness.fnos` | 113 | **640×640** | 640×640（与前者字节完全相同） | 白底 + 近黑鲸 |
| `techysy/deepseek-harness-fnos` | 77 | **128×128** | 256×256 | 近黑鲸，满版 |
| `FNOSP/fnos-dsh` | 61 | 64×64 | 256×256 | 白底 + 官方蓝鲸 |
| `10000ge10000/deepseek-harness-fpk` | 44 | 64×64 | 256×256 | 白底 + 蓝鲸 |
| `javen-yan/deepseek-harness-fnos` | 17 | 64×64 | 256×256 | 白底 + 蓝鲸 |

三条结论：

1. **`ICON.PNG` 的 64×64 不是安装器的硬约束。** 640、128 都有先例；yuexps 干脆把
   `ICON.PNG` 和 `ICON_256.PNG` 放成**同一个 640×640 文件**（163187 字节完全相同），
   照样能发、能装。所谓硬校验只存在于 `fnpack build`（MAA-FnOS 构建指南原文：
   「fnpack 会强制校验 ICON.PNG(64x64)」）——我们是自研 `build.sh` 打 tar，不受这条限制。
2. **清晰度主要由对比度决定，不是像素。** 两个热门项目都用近黑鲸（对比约 21:1）；
   只有 FNOSP 沿用官方蓝鲸（`#4D6BFE` 配白底约 4.3:1）且只给 64px，把它放大看，
   眼睛糊成一团、边缘全是锯齿——和我们 0.6.1/0.6.2 的观感完全一致。
3. 结论：**256×256 源 + 深蓝底 `#23328C` + 白鲸**（对比 11:1）。56px 模拟下，
   品牌蓝版明显「软」，深蓝版轮廓干净，与近黑版差距很小但保住了蓝色品牌感。

**0.6.4 修法**：`ICON.PNG` / `ICON_256.PNG` / 两张入口图统一为 256×256 深蓝版；
`build.sh` 校验放开为 64 或 256；`probe/05` 增加包根图标尺寸断言，读到 64 直接 WARN。

**风险与回退**：若安装器报图标规格不符，退回 0.6.3（数据不受影响），改走
「64px 极限简化」——去掉眼睛、尾鳍做成整块、只留可辨认剪影。

**0.6.5 改用官方成品图标（用户要求「不修改直接使用」）**：

前面所有轮次用的都是 `website/public/favicon.svg`——那是官网顶部的 **50×50 站点小标**，
细线条蓝鲸，本来就不是给应用图标用的。官方仓库里另有三套真正的产品图：

| 路径 | 尺寸 | 说明 |
|---|---|---|
| `apps/web/public/icon-512.png` | 512×512 | 网页 / PWA 应用图标 → **采用** |
| `apps/web/public/icon-192.png` | 192×192 | 同款小档 |
| `apps/web/public/apple-touch-icon.png` | 180×180 | iOS 用 |
| `apps/desktop/resources/icon.png` | 1104×1104 | 桌面端，带纸张纹理噪点，小尺寸不适用 |
| `apps/desktop/resources/icon.svg` | 1104 矢量 | 桌面端矢量源 |

视觉上是**浅色底 + 深色鲸鱼实体色块**（对比约 18:1），与 favicon 的细线条蓝鲸
是两套完全不同的东西。社区热门项目清一色用深色鲸鱼，正是因为跟的是这套产品形象。

四个位置原样复制同一个文件，SHA-256 一致（`0aa6ff8c…`），未缩放、未调色、未重绘。
`build.sh` 校验相应放宽为「正方形 / 边长 64~1024 / ≤1024KB」。

**0.6.5 装包后的实测结论（2026-10-28 01:04）**：用户装完反馈**「好很多」**，图标清晰。

坐实了真正的根因：**不是分辨率，也不是配色，而是用错了资源**。

回顾四轮的误判路径，每一轮都在正确的方向上修，但修的对象是错的：

| 轮次 | 改动 | 为什么没用 |
|---|---|---|
| 0.6.2 | 入口图 64 → 256 像素 | 平台详情页读的是包根 `ICON.PNG`，改错了文件 |
| 0.6.3 | 深蓝底 + 白鲸剪影（提对比度） | 图形换了，但画的还是 favicon 那只细线条鲸鱼 |
| 0.6.4 | `ICON.PNG` 也提到 256 + 加深到 `#23328C` | 文件对了、像素够了，但素材本身是站点小标 |
| **0.6.5** | **原样用官方 `icon-512.png`** | **一次到位** |

**教训（按踩坑顺序）**：

1. **先确认「官方图标」指哪个资源**。同一个仓库里 favicon（50×50 站点小标）、PWA icon、
   桌面端 icon 是三套完全不同的图。拿细线条小标去填 96px 的显示位，怎么调都吃亏。
2. **再确认渲染的是哪个文件**。界面糊的时候容易去改 `ui/images/` 那两张，而平台读的
   是包根 `ICON.PNG`——先定位被读取的那张，再谈画质。
3. **最后才算像素和对比度**：显示尺寸 × DPR = 需要多少物理像素；图形在目标尺寸下
   还剩几层可分辨的对比。只算第一笔会把对比度问题误判成分辨率问题。

另外两条附带结论仍成立，可作为以后换图时的检查项：

1. `ICON.PNG` 的 64×64 不是安装器硬约束（有 640、128 的先例），放开尺寸是安全的；
2. 对比度决定小尺寸锐度：浅底 + 深色实体色块约 18:1，品牌蓝配白底只有 4.3:1。

### F22 「没有默认工作区」：dsh 的初始化被 HOME 布局挡住 ⚠️（0.6.7 待装包验证）

**现象**：点图标进 dsh，工作区下拉里只有自己建的 `Project` 和「+ 添加工作区…」，
内置的「默认工作区」不存在。

**根因链**（每一环都有真机输出作证，不是推断）：

1. `dsh-api-workspace-controller` 的 `defaultWorkspaceDirectory()` 在 linux 上执行
   `xdg-user-dir DOCUMENTS`，然后拼成 `<文档目录>/deepseek-harness/default-workspace`
   （`DEFAULT_WORKSPACE_DIRECTORY = "default-workspace"`）。
2. `xdg-user-dir` **只读** `$XDG_CONFIG_HOME/user-dirs.dirs`（默认 `~/.config/user-dirs.dirs`），
   不读同名环境变量。我们的 `HOME` 是 `.../workspace/.dsh-home`，里面没有 `.config`。
3. 文件缺失时它**原样回显 `$HOME`**——实测输出 `/vol1/@appshare/dsh/workspace/.dsh-home`。
4. dsh 紧接着判 `directory === homedir()`，命中即抛
   `system Documents directory is unavailable`。
5. `workspaceRegistry.initializeDefault()` 因此不创建，前端只弹一条
   `defaultWorkspace.failed`：「无法创建默认工作区，请通过“选择工作区”选择文件夹」。
6. **最要命的是它只尝试一次**：守卫条件是「`workspaceIds` 空 + 无归档 + 无会话」。
   只要手动加过工作区或聊过一句，自动创建就**永久失效**
   （源码注释：*deleting that registration permanently disables automatic creation*）。
   所以「删掉 Project 再重建」也换不回来，只会连会话一起丢。

**为什么开发机上是好的**：win32 分支走 `powershell.exe` 取 `MyDocuments`，永远有值，
与 HOME 无关。这是**纯 linux / 无桌面环境**才踩到的坑，又被我们「HOME 塞进共享目录」
的布局放大了一档。

**修法（0.6.6 写好，随 0.6.7 一起发）**：

| 改动 | 位置 | 作用 |
|---|---|---|
| `ensure_documents_dir()`：写 `$HOME/.config/user-dirs.dirs`（`XDG_DOCUMENTS_DIR=<共享目录>`）、建 `<共享目录>/deepseek-harness/default-workspace`、属主交 `dsh:AppUsers`、`export XDG_CONFIG_HOME=$HOME/.config` | `cmd/main` | 治本：让 dsh 自己的 `initializeDefault` 跑通 |
| `ensure_default_workspace()` + `cmd/ensure-default-workspace.mjs` | `cmd/main` | 治标：注册表已非空的老用户，停机状态下按 canonical 路径去重合并，补一条 `title="default-workspace"` 并写 `defaultWorkspaceId` |
| 11 条断言（文档目录取值 ≠ HOME、目录已建、补登记幂等、原有会话未被破坏） | `fpk/selftest.sh` | 防回归 |

**三个必须记住的约束**：

1. `title` 只能用英文常量 `default-workspace`。前端 `workspaceDisplayTitle()` 拿它比对后
   才本地化成「默认工作区」；直接写中文会变成一条普通工作区，名字对了但“默认”语义没了。
2. 补登记**必须在 dsh 停止时**做。注册表由 `dsh-storage-json` 管，dsh 内存里有副本，
   运行中改会被覆盖甚至写坏。`do_start` 里放在 `is_running` 早退之后、`spawn` 之前，
   正好满足。
3. 路径必须 `realpath` 之后再写。dsh 的唯一性判据是「canonical 字符串相等」，
   写非规范路径会造出重复工作区。


### F23 「访问权限」页被我们自己关掉了，任意文件夹都加不成工作区 ⚠️（0.6.7 待装包验证）

**现象**：dsh 里只能往共享目录（`应用文件/dsh/workspace`）里放东西，想把「我的文件」
里的某个文件夹当工作区用，怎么样都不成 —— 应用设置里根本没有「访问权限」这一页
（对比 Gitea 有：`允许访问以下文件夹` + `读写` + `添加`）。

**根因**：`fpk/manifest` 写着 `disable_authorization_path="true"`。

这条是 0.4/0.5 时期的保守选择（当时没打算让 dsh 碰用户文件），但它和 dsh 的定位矛盾：
dsh 是通用工作台，工作区天然是用户的任意目录。官方文档把两种方式分得很清楚：

| 方式 | 谁授权 | 我们能不能用 |
|---|---|---|
| `config/resource` 的 `data-share` | 安装时自动，**只给应用自己那块目录** | 已用（`dsh/workspace`） |
| 应用设置 →「访问权限」 | **用户自己挑文件夹**，平台把 ACL 授给应用用户 | **被 `disable_authorization_path=true` 关掉了** |

关掉之后，应用用户 `dsh` 对 `/vol1/1000/...` 这类用户目录没有任何权限（POSIX 位通常是
`700`，属主是用户本人），于是即便在 dsh 的目录选择器里点进去也只会 `EACCES`。

**另一半关键事实（决定了只要开权限就够，不必改 dsh）**：dsh 的目录选择器是自适应的
（`dsh-host-directory-picker-auto`），判定表第一行就是「绑定地址不是 loopback → browse」。
我们的 launcher/dsh 绑的是 `192.168.0.114`，所以必定走 `browse` 后端；而
`dsh-host-directory-picker-browse` 的 README 明确写着「**全盘可浏览** —— 没有按部署限定的
浏览根；`workspace.create` 接受任意路径」，`list()` 从家目录起步并带 `/` 面包屑。
也就是说：**权限到位之后，路径根本不需要我们额外暴露，用户自己就能点过去。**

**修法（0.6.7）**：

| 改动 | 位置 | 作用 |
|---|---|---|
| `disable_authorization_path="false"` | `manifest` | 应用设置里出现「访问权限 → 允许访问以下文件夹」，可加任意目录（读写/只读） |
| `log_accessible_paths()` 把 `TRIM_DATA_ACCESSIBLE_PATHS` 逐条写进 `info.log`（`auth-paths:` 前缀，标「读写 / 只读 / 不存在 / 进不去」） | `cmd/main`（`do_start`，拉起 dsh 前） | 排错第一现场：分清「没授权」「平台没传进来」「ACL 没生效」 |
| 6 条断言（manifest 开关、日志记录、读写/不存在两种分支、条数统计） | `fpk/selftest.sh` | 防回归 |
| `probe/05` 新增两条验收 | `probe/05-verify-fpk.sh` | 装完就能看出开关是否生效 |

**使用路径**（写进 README / RUNBOOK）：

1. 应用中心 → dsh → 设置 → **访问权限** → `+ 添加` → 选文件夹 → 权限选 **读写**；
2. 回 dsh → 工作区下拉 → **+ 添加工作区** → 点首屏的 **「可访问目录」** → 选中那个文件夹（0.6.8 起；
   0.6.7 时代这里点不过去，见 F24）；
3. 之后这个目录就是这个会话的 cwd，dsh 的读写/终端都在里面。

**两个坑要记住**：

1. **只读授权能加进工作区，但会话跑不动**：dsh 要在工作区里落 `.dsh` 缓存/产物，
   写失败会在很靠后的步骤报错，看起来像 dsh 的 bug。授权时优先选「读写」。
2. **授权后不用重启应用**：ACL 是平台立即写的，`dsh` 进程下一次 `stat/opendir` 就能过；
   只有 `auth-paths:` 这行日志要等重启才更新。别为了看一眼日志去重启（会换代 token）。

**结论（2026-10-28 真机）**：`0.6.7` 装上后「访问权限」页确实出现了，`存储空间1/T366的文件/Project`
可以加成「读写」，平台也把路径传进了 `TRIM_DATA_ACCESSIBLE_PATHS`。**这一条本身成立**；
但「加进授权」不等于「在选择器里点得到」，那是 F24。


### F24 「选择工作区目录」点不到刚授权的文件夹：选择器从隐藏的家目录起步 ⚠️（0.6.8 待装包验证）

**现象**：授权已经加好（应用设置 → 访问权限里，`存储空间1/T366的文件/Project` 一栏显示「读写」），
但 dsh 里「+ 添加工作区」弹出的「选择工作区目录」只有这些：
`channel-pack / openai-gateway / our-free-model / profiles / Project / sessions / storages` ——
**全是 `.dsh-home` 里的东西**，用户授权的文件夹不在里面，而且退不出去。

**根因（两条叠加，都在源码里核实过）**：

1. `dsh-host-directory-picker-browse/lib/index.js` 的 `list(path)`：`path` 缺省时
   `const target = resolve(path ?? home)`，而 `home = homedir()`。我们的 dsh 以
   `HOME=/vol1/@appshare/dsh/workspace/.dsh-home` 运行 → 首屏列的就是这个隐藏的应用数据目录。
2. `dsh-client-ui-directory-picker-browse/lib/client.js` 的 `displayCrumbs()`：一旦面包屑里出现
   `listing.home`，就把它**以上**的部分整段丢掉，只留一个 `t("browser.home")`（中文「主目录」）按钮。
   于是从首屏往上走到 `/vol1` 的路被 UI 掐断了。唯一出口是右上角的铅笔图标
   （`browser.editPath`）—— 打开一个输入框，可以手打绝对路径。

也就是说：**F23 把「权限」这一环打通了，但「导航」这一环还断着**。dsh 原本假设家目录里就有用户的文件
（桌面端 `/home/xxx` 确实如此），我们这套把家目录换成了应用数据目录，这个假设就不成立了。

**修法（0.6.8）**：启动时（拉起 dsh 之前）把每个授权目录软链进 `$HOME/可访问目录/`，
让它们出现在对话框首屏。约束条件：

| 约束 | 为什么 |
|---|---|
| 只清软链，不碰真实文件 | 这个目录归我们管，但「删」必须可解释；清的是上一轮的 `ln -s` |
| 包含 `$DSH_HOME` 的授权路径跳过 | 否则 `可访问目录/workspace/.dsh-home/可访问目录/…` 无限递归，选择器能一直往下点 |
| 被别的授权目录包含的路径合并掉 | 授权了 `/vol1/1000` 又授权 `/vol1/1000/Project` 时，只留外层一条，避免重复 |
| 链接名 = 目录名 | dsh 用「用户选中的路径最后一段」当工作区标题，名字取歪标题就歪 |
| 平台没传 `TRIM_DATA_ACCESSIBLE_PATHS` 时不清空 | 手动 `appcenter-cli start` 可能没有环境变量；清掉只会让用户突然点不到 |
| 日志把「挂载决定」与「建链结果」分成两行 | `ln -s` 要特权，某些文件系统建不了；但「该不该出现在首屏」的判断仍成立，两者混在一行会让断言在 Windows 上靠 WARN 蒙对、在 Linux 上反而误报（0.6.8 打包时就是这么翻的） |

软链只当**入口**：`workspace.create` 走 `realpathNormalize`（`fs.realpath`），登记的仍是真实路径，
dsh 的路径去重判据不受影响。

**为什么不做「启动时自动把授权目录登记成工作区」**：用户删掉一个工作区后，下次启动又会被加回来，
和 dsh 自己的语义冲突（源码注释：*deleting that registration permanently disables automatic creation*）。
软链是被动入口，不会和用户的操作打架。

**0.6.7 上的临时绕法**（不用等新包）：在「选择工作区目录」里点**右上角铅笔图标**，
直接输入绝对路径（如 `/vol1/1000/T366的文件/Project`）回车，再点「打开」。
README / RUNBOOK 里也写了这条，但正确形态是「可访问目录」里直接点。


### F25 授权探测是 root 视角：日志说「读写」，dsh 一个文件都读不了 ⚠️（0.6.8 待装包验证）

**现象**（2026-10-29 00:30，真机）：工作区 `/vol1/1000/Project` 里 agent 逐个文件报
「无法读取（owner:nobody, mode 0000）」，连 `.readme.md` 都打不开；而启动日志那行
`auth-paths:` 明明白白写着「读写」。两边互相矛盾，等于日志把排错方向带反了。

**根因在我们自己的探测里**：`log_accessible_paths()` 用的是 `[ -r ]` / `[ -w ]`，
而生命周期脚本以 **root** 运行。root 有 `CAP_DAC_OVERRIDE`，**绕过 mode 位** ——
`0000` 的文件在 root 眼里照样「可读可写」。真正跑 dsh 的是普通用户 `dsh`，
同一批文件就是 `EACCES`。

所以这条日志的语义本来就该是「**dsh 能不能用**」，却被写成了「root 能不能读」。

**修法（0.6.8）**：

| 改动 | 作用 |
|---|---|
| `probe_as_app()` | root 时用 `runuser -u` / `su -s` 切到应用用户再 `test`；两者都没有才退回自身身份并留一条 WARN |
| `sample_unreadable()` | 目录可进时抽查前 6 项，数出 dsh 读不了的比例，并带上首个样本的「文件（属主:组 权限）」 |
| 日志新分支 | `auth-paths: <路径> （目录可进，但抽查 6 项里有 3 项 dsh 读不了，如 README.md（nobody:nogroup 0000）；当工作区用时 dsh 会报「无法读取」，要先把这批文件的属主/权限修好）` |
| `probe/05` | 日志里出现「进不去 / 读不了」直接 WARN，并指向修复动作 |

**只报告，不动数据**：那批文件是 `nobody:nogroup` + `0000`，不是应用创建的；
启动脚本去 `chown -R` 用户文件是越界行为（而且会盖掉 FNOS 的 ACL，见 F23 的说明）。
修复在数据侧：文件管理里把权限「应用到子文件夹和文件」，或由管理员用 root 修正属主。

**顺带一个判断依据（已修正）**：这批文件不是 `dsh` 写的。但「属主是 `nobody`／未映射 UID」
这个说法是**我读错了 `find` 的格式** —— `-printf '%U:%G'` 里的 `%U`/`%G` **本来就是数字 UID**
（`%u`/`%g` 才是用户名），所以「984 查不到用户」是假象。`getfacl` 一查就现形：**984 = `dsh-qddev`**，
一个独立的应用用户（不是本包创建，仓库里搜不到这个名字）。

**真机取证（2026-10-29 00:41 / 00:52 / 01:03，root 只读诊断）**：

```console
uid=1000(T366) gid=1001(Users) groups=1001(Users),1000(Administrators)
uid=971(dsh)   gid=901(AppUsers) groups=901(AppUsers),966(dsh)
d--------- 1 T366 Users 262 Project          # stat 说 0000
user::---  group::---  other::---            # 目录 getfacl 只有基础三条
984:979(=dsh-qddev) 600 README.md index.html      0:0 700 .dsh deepseek-harness dsh-run dsh-tls

runuser -u T366 -- head README.md   → 成功
runuser -u dsh  -- ls   "$P"        → 成功（readdir）
runuser -u dsh  -- ls   "$P/css"    → 成功
runuser -u dsh  -- head README.md   → Permission denied
```

`setfacl -R -m u:dsh:rwX "$P"` 之后 ACL **确实写进去了**：

```console
# file: README.md
# owner: dsh-qddev
user::rw-  user:dsh:rw-  group::---  mask::rw-  other::---
```

`user:dsh:rw-` + `mask::rw-` 在 POSIX 语义下**必须放行**，可 `runuser -u dsh -- head` 仍然
EACCES。结论：

1. **这台机器上 Project 的访问判定不吃 POSIX ACL**（也不完全吃 mode：`0000` 的目录能让
   非属主 `readdir`）。别再在这棵树上用 `setfacl` 试 —— 写进去了也不生效。
2. 两次推断都已作废：v1「0000 连属主都进不去」、v2「984 是未映射 UID」。两次都是拿
   `stat`/`find` 的输出反推可访问性，而没实测。**以后只认 `runuser -u <真实用户>`**。
3. 真正可行的是把**属主和 mode 归一到 mode 语义**（`chown` + `chmod 644/755`，让 `dsh` 从
   `other` 位读），或用文件管理界面的「应用到子文件夹和文件」。
4. 一棵树里混着三个属主（`1000:1001` T366 / `984:979` dsh-qddev / `0:0` root），说明它被三个
   身份写过。**`dsh-qddev` 已确认是另一套 dsh 包的应用用户**：

   ```console
   dsh-qddev:x:984:901::/home/dsh-qddev:/usr/sbin/nologin
   drwx------ 1 dsh-qddev dsh-qddev 0 Sep 10 00:35 /vol1/@appshare/dsh-qddev
   ```

   gid 901 就是 `AppUsers`，跟现在 `dsh` 的附加组之一相同，但 **uid/gid 都不同**（984:979 vs
   971:966）。也就是说这台机器上装过**两套 appname 不同的包**，Project 里那批网页文件是旧包
   （`dsh-qddev` 用户）写的。

5. **由此得出一条硬约束：应用用户名不能变。** `cmd/main` 是
   `DSH_USER="${TRIM_USERNAME:-dsh}"` —— 用户名由平台按 `fpk/manifest` 的 `appname`
   （本包是 `appname="dsh"`）生成，不是我们写死的。旧包 appname 里带 `qddev`，平台就造出了
   `dsh-qddev`。一旦改 appname，平台换一个用户，`$HOME`（`.dsh-home`）、`workspace.json`、
   以及用户授权目录里由旧用户写下的文件**全部归属断裂**，新用户读不到，症状正是本次这一串
   （agent 报「无法读取」、默认工作区建不出来）。升级只能换版本号、**不能换 appname**；
   真要换就得配套写数据迁移（`chown -R` 旧 uid → 新 uid）。

处理：Project 的权限史太脏，**不拿它做验收** —— 新建一个干净目录跑 F22/F23/F24；Project 单独
用 `chown -R 1000:1001` + `chmod -R u+rwX,go+rX` 收拾。命令在 `RUNBOOK.md` 5.5。


### F26 Web 端附件上传一律失败：dsh 的 fsync-to-root 撞上飞牛卷目录 000 ✅（2026-10-29 结案）

**现象**（2026-10-29，真机 0.6.x）：dsh Web 聊天里附任何文件（图片未测），卡片显示
「上传失败，点击重试」，重试无意义。与文件无关：1.7MB PDF 与纯 ASCII 文件名副本同样失败。

**定位过程**（全程未上 NAS）：

1. 本地 `npm pack` 拉下与包内同版本 `@deepseek-ai/dsh@0.2.1-rc.3` 全依赖树，读上传链路：
   浏览器 Blob Worker XHR → `POST /api/session/uploadFileBinary?sessionId&name`
   （`application/octet-stream`，流式）→ `FileUploads.uploadStream()` →
   `LocalAttachmentStore.saveFileStreamVerbatim()` 落盘到 `$DSH_HOME/attachments/v1/`。
   **该路径对通用文件没有任何大小/类型限制**（图片才有 20MB / png-jpeg-webp-gif 限制），
   文件名会消毒（`fileLeafName()`）。所以「PDF 不支持」「体积超限」都不成立。
2. 从开发机经 launcher（内网 auto 放行）拿到 302 目标，令牌换 cookie 后 curl 直打该端点：
   路由、鉴权、参数校验全部正常（假 sessionId 回规范的 `session/not-found`）。
3. 拿到真实 sessionId（用户 F12 截图）后端到端复现，**小文件与大 PDF 同错**：

   ```console
   POST /api/session/uploadFileBinary?sessionId=session-12bf13b0-…&name=…
   → 200 {"ok":false,"error":{"code":"gateway/internal",
       "message":"failed to store file upload: Error: EACCES: permission denied,
                 open '/vol1/@appshare/dsh'"}}
   ```

**根因（两层，都在文件系统，与 dsh 配置无关）**：

1. `/vol1/@appshare/dsh`（共享目录根）被弄脏成 `root:root 000`——平台卸载「临时改 000」
   未恢复 + 属主漂移（T11/P6 的坑再+1）。dsh 用户进不去，`runuser -u dsh -- ls` 复现 EACCES。
2. 修好这层后错误上移到 `/vol1/@appshare`，再取证发现 **`/vol1` 和 `/vol1/@appshare`
   也是 `root:root 000`**，而 `@appcenter/@appdata/@appconf` 均为出厂 755 —— 000 不是飞牛默认，
   是同一事故（同日 SSH 主机密钥变更，疑似系统重置/更新）弄脏的。

**为什么卷目录 000 必杀附件功能**：`dsh-attachment-local` 的落盘设计是「durability 证明」——
`ensureDurableHome()` 以**文件系统根 `/` 为边界**，把 DSH_HOME 的每一层祖先
`open(dir, O_RDONLY)` + `fsync`（`stageImmutableObject` 写暂存前、`publishImmutableAlias`
落位后各走一遍）。飞牛对卷目录默认只给应用用户穿越（x）不给读（r）——`test -x` 全过、
`open(O_RDONLY)` 被拒。**祖先链上任何一层无 r 位，附件功能整体不可用**，且每次上传都撞
（失败结果不被 `durableHomes` 缓存）。会话/工作区等其余功能不走这条 fsync 链，所以只有上传挂。

**修复（2026-10-29 实测有效）**：

```bash
chown dsh:dsh /vol1/@appshare/dsh        # 共享目录根属主回 dsh（000 → 700）
chmod o+rx /vol1 /vol1/@appshare         # 卷目录恢复出厂 755；dsh 需 r 才能 open 做 fsync
```

改完**无需重启**（fsync 链每次上传现走）。验收：同一真实会话 curl 上传 10B 小文件与
1.7MB PDF 均 `{"ok":true,"value":{"receiptId":…}}`，PDF 68ms；Web 端重传卡片应变绿。

**安全代价与升级注意**：`o+rx` 让本机普通用户能列出 `/vol1` 与 `@appshare` 的**顶层目录名**；
各应用/用户数据目录自身仍 700，内容不泄露。这是 dsh「fsync 到根」设计与飞牛「卷目录不开放
列目录」的硬冲突，二者只能取其一。**任何把 `/vol1`/`@appshare` 改回 000 的平台行为
（卸载、系统更新）都会让附件再次全灭**，症状：上传回 `EACCES ... open '/vol1/@appshare'`。
probe/05 的授权目录探测测的是穿越（x），覆盖不到这条 fsync 链（r）。

**教训**：① node 报的 `open '<路径>'` 是**请求目标**，不一定是失败的组件——
`EACCES open '/vol1/@appshare/dsh'` 修复后变成 `open '/vol1/@appshare'` 是同一代码走得更深了，
不是权限「变坏」；② `ls 目录` 需要 r，判定穿越要用 `test -x` / `ls -d`；
③ 本机权限判定不吃 POSIX ACL（F25 结论再次确认），修复只认 `chmod/chown` + `runuser` 实测。

### F27 dsh agent 会话环境三连坑：工作区不可写 / 检查工具 schema 误导 / 沙箱只读 ⚠️→坑1已结案（2026-10-29 自会话导出日志分析）

**来源**：会话 `session-12bf13b0` 导出包（`session.v4.jsonl`，192 事件，模型 kilo-auto/free），
任务「创建一个联网搜索 DSH 插件」。无崩溃（9 个 job 全 completed），但流程被三类环境问题打断：

**坑 1：会话工作区 `/vol1/1000/Project` 对 dsh 用户不可写**✅（2026-10-29 结案）
（浪费 3 次调用 + 逼出权限提升）。会话时点属主是 `nobody:nogroup`（事故残留），
随后被改回 `T366:Users 755`，且 ACL 里**已写明 `user:dsh:rwx`、`mask::rwx`**——
但 `runuser -u dsh` 实测 mkdir 仍被拒，**POSIX ACL 在平台共享目录上不生效**（F25 结论第三次验证），
`/vol1/1000` 本身 000 也照样可穿越（`test -x` 过）。硬写 chmod/setfacl 均无效。
**有效修法 = 走 dsh 自己的目录授权通道**：dsh Web 界面「访问权限/可访问目录」里把
`/vol1/1000/Project` 授权为读写 → 重启应用 → `auth-paths:` 登记为「读写」
（20:02 生效）→ `runuser -u dsh` 实测 `mkdir` 通过（`dsh-write-ok`）。
另：owner 基础权限曾为 `user::---`（T366 对自己目录无基础位），已用
`setfacl -m u::rwx,g::r-x /vol1/1000/Project` 补回。
**教训**：这台机器上给应用授目录权限，**只认 dsh「访问权限」授权 + 平台权限库，
不认文件系统层的手工 ACL/mode**；诊断时 `getfacl` 只能当参考，`runuser` 实测才算数。

**坑 2：`cordis_inspect_query` 的 `input` schema 误导**（连续 6 次调用被拒）。
报错 `"input" must be an object`，但 agent 传 `{service:"web"}`、`{}`、嵌套包一层全被拒——
schema 声明 input 可选、additionalProperties true，实际校验却不是。6 次浪费才摸对调法，
属于工具 schema 与实现不一致的可用性问题（kilo-auto/free 的 agent 在 thinking 里明确困惑）。

**坑 3：workspace-write 沙箱把 `/vol1/@appshare/dsh/workspace` 当只读**。
bash `mkdir` 报 `Read-only file system`（write 工具却能直接写入——两通道策略不一致），
需要 escalation 到 danger-full-access 才能继续，一次任务里 **3 次 allowed-once 审批打断**。
结束后用户把权限**永久**切到 `danger-full-access` + `approval never`——
注意该变更跨会话持久，**插件装完建议改回 `workspace-write` + `ask`**，否则后续会话全程无审批。

**附**：kilo-auto/free 把 reasoning 独白混进 assistant 正文（3 段困惑自言自语直接展示给用户），
观感问题，留意是否模型侧未分离 reasoning 通道。

### F28 Web 界面「添加插件」一律失败：运行时里没有 pnpm ⚠️（2026-10-30 修复，待真机验证）

**现象**（0.6.x 真机）：Web 界面 → 插件 → 添加插件，输入任意包名（本次是 `billion-context`）
都回同一句：

```console
无法获取插件信息: Command failed with ENOENT: pnpm view billion-context name version
description dsh --json --registry=https://registry.npmmirror.com/ --config.fetch-retries=0
spawn pnpm ENOENT
```

**先排除包名**：`billion-context` 在 npmmirror 上存在（latest `0.1.209`，2026-10-30 实查）。
`spawn pnpm ENOENT` 是 Node `child_process` 在 PATH 上找不到可执行文件时的原话，
与包名、registry、网络都无关。

**根因**：dsh 自己不做包管理，插件安装/查询全部**转发给 pnpm**（`dsh plugin …` 原样转给
pnpm，Web 端走同一套 `runPluginCommand`），而且 spawn 的是裸命令名 `pnpm`，只认 PATH。
本应用的运行时是从 `nodejs_v24` 里**只拷了 `bin/node` 一个文件**（`build.sh` 原注释：
「npm/npx 是软链，运行 dsh 用不到」）—— 这句话在 0.6.8 之前成立，从插件功能要用 pnpm
那一刻起就不成立了。

| 检查 | 结果 |
|---|---|
| `runtime/node/bin/` 内容 | 只有 `node`（无 npm / npx / pnpm） |
| 系统 PATH 有没有 pnpm | 没有（fnOS 不带，`nodejs_v24` 应用里也没有） |
| 包是否存在 | 存在，与本次失败无关 |

**修法（0.6.9）**：

| 位置 | 改动 |
|---|---|
| `build.sh` | full 模式把 `pnpm@10.34.9` 装进 `app/runtime/pnpm`，在 `app/runtime/node/bin/pnpm` 生成 sh wrapper；打包前用 `pnpm --version` 自检，装不起来就中止 |
| `cmd/main` | 启动时若 wrapper 存在则 `export PATH="$RUNTIME/node/bin:$PATH"`，日志写 `start: pnpm=… version=…`；缺失只 WARN，不阻断启动 |
| `selftest.sh` | 断言日志里有 pnpm 路径、版本取自包元数据；Linux 上再读子进程 `/proc/<pid>/environ` 确认 PATH 真被前置（只信日志会被「写了但没 export」骗过） |
| `manifest` | `0.6.9` + changelog |

**为什么钉 10.34.9，而不是 latest（12.x）**：dsh 的引导文案让用户改
`pnpm-workspace.yaml` 里的 `allowBuilds`，这个字段 **10.26** 才引入，v11 起成为唯一写法
（`onlyBuiltDependencies` 等被移除）。10.34.9 是 10.x 最新维护版（engines `node>=18.12`），
与自带 node 24 兼容；12.x 才发布几个月，没必要替 dsh 冒这个险。

**为什么用 wrapper 而不是软链**：pnpm 的 shebang 是 `#!/usr/bin/env node`，会命中系统
PATH 上的 v22.19（`cmd/main` 头部注释就记着这个坑）；wrapper 显式 `exec "$here/node"`，
让 pnpm 与 dsh 跑在同一个 v24 上（`process.execPath` 也决定子脚本用哪个 node）。
顺带绕开软链在 fpk 解包/复制时断链的风险（F20）。

**第一次 NAS 构建的翻车（2026-10-30 22:10，自检拦住，没出废包）**：

```console
ERROR: pnpm wrapper 无法运行：Error: Cannot find module
'/root/dsh-fnos/fpk/app/runtime/node/pnpm/node_modules/pnpm/bin/pnpm.cjs'
```

wrapper 里的相对路径少写了一级 ——`$here` 已经是 `runtime/node/bin`，`../pnpm` 指向
`runtime/node/pnpm`（不存在），正确是 `../../pnpm`。教训不在算术，而在**这条路径从来没被
执行过**：本地自测的假 wrapper 只 `printf` 一个版本号，压根不碰 pnpm.cjs；而 build.sh 里
`pnpm --version` 那条自检是**第一次真正跑它**的地方 —— 自检写作的代价是十分钟，不写的代价
是一个装得上、但插件永远报 ENOENT 的包。

现在 wrapper 自己也带一句「找不到 cjs 就 127 + 明确提示」，并且 `selftest.sh` 把 build.sh 里
的 heredoc **原样抽出来**、按真实布局（`runtime/node/bin/` 与 `runtime/pnpm/`）在沙箱跑一遍、
故意换 cwd 调用，层数写错当场失败（`wrapper 能找到 pnpm.cjs（换 cwd 调用）` 那条）。这条断言做过反向验证：把 `../../pnpm`
改回 `../pnpm`，自测立刻报 `找不到 …/node/bin/../pnpm/…`，改回即通过。

**临时解法（不想等打包时）**：NAS 上以 root 手工补一份，再把入口链进系统 PATH：

```bash
R=/var/apps/dsh/target/runtime
cd "$R" && /var/apps/nodejs_v24/target/bin/npm install --prefix pnpm pnpm@10.34.9
cat > "$R/node/bin/pnpm" <<'EOF'
#!/bin/sh
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/node" "$here/../pnpm/node_modules/pnpm/bin/pnpm.cjs" "$@"
EOF
chmod +x "$R/node/bin/pnpm"
ln -sf "$R/node/bin/pnpm" /usr/local/bin/pnpm    # dsh 进程的 PATH 含 /usr/local/bin
appcenter-cli restart dsh
```

代价：`/usr/local/bin/pnpm` 落在系统盘，重装要重做；`target/` 被新包替换后若没带 pnpm，
软链会悬空。**正解仍是装 0.6.9**。

**验收判据**：`grep 'start: pnpm=' /var/apps/dsh/var/info.log` 出现
`…/runtime/node/bin/pnpm version=10.34.9（已前置到 PATH）`；然后在 Web 界面添加插件，
错误应从「无法获取插件信息」变成能读到版本号并开始下载；装完若列表没变化，重启应用一次
（插件装进 `.dsh-home` 下的 profile 子目录，重启才会重新加载 bundle）。

### F29 插件信息仍读不出来：pnpm 把 `view` 转发给了系统 npm ⚠️（2026-11-01 修复，待真机验证）

**现象**（0.6.9 真机）：`spawn pnpm ENOENT` 已经消失，但换成另一句：

```console
无法获取插件信息: npm error Class extends value undefined is not a constructor or null
npm error A complete log of this run can be found in:
npm error   /vol1/@appshare/dsh/workspace/.dsh-home/.npm/_logs/2026-11-01T08_28_11_411Z-debug-0.log
```

注意这里是 `npm error`，日志也落在 `.npm/_logs/` —— **动手的是 npm**。

**排查经过**（每一步都排除了一个方向）：

| 检查 | 结果 | 排除了什么 |
|---|---|---|
| `pnpm view dsh-free-search …`（本地同版本 10.34.9 复现） | 正常返回 JSON | pnpm 本身没坏 |
| npm 调试日志 `verbose cli` | `/vol1/@appcenter/dsh/runtime/node/bin/node /usr/local/bin/npm` | dsh 传的命令/参数原样给了 npm |
| 在 pnpm wrapper 里打日志 | `argv0=…/runtime/node/bin/pnpm args=view dsh-free-search …` | 我们的 pnpm **确实被执行了**，PATH 前置有效 |
| `/proc/<dsh pid>/environ` 里的 PATH | `runtime/node/bin` 排第一 | 不是 PATH 没传进去 |
| profile 的 `package.json` / 全局配置 | 没有 `packageManager`、没有 `npmCommand` | 不是配置把命令改成了 npm |
| pnpm 源码 `run-npm/lib/index.js` | `const npm = npmPath ?? "npm"` | pnpm 的 `view`/`config` **自己转发给裸命令 npm** |

**根因**：`runtime/node/bin` 里只有 `node` 和 `pnpm`，**没有 npm**。pnpm 转发时按 PATH 找
`npm`，落到系统那份 `/usr/local/bin/npm`（`npm 10.9.3`，2026-10-08 随系统 node 装的），
而我们的 wrapper 用 `$here/node`（v24）去跑它 —— npm 10.9 与 node 24 不兼容，
在 `minizlib` 里 `Class extends value undefined` 直接崩。

一句话：**0.6.9 修好了「找不到 pnpm」，但 pnpm 干活还需要 npm，两个必须成套。**

**修法（0.7.0）**：

| 位置 | 改动 |
|---|---|
| `build.sh` | 新增 `DSH_NPM_VERSION=11.21.1`，装进 `app/runtime/npm`，在 `app/runtime/node/bin/npm` 生成同构 wrapper；两条版本自检 + **一条端到端自检**：`cd /tmp && PATH=<runtime>/node/bin:$PATH pnpm view lodash version`，输出必须是版本号 |
| `cmd/main` | 启动日志增加 `start: npm=… version=…`；缺失时 WARN 并说明会转发给系统 npm |
| `selftest.sh` | 假 npm + npm wrapper 模板按真实布局跑一遍（两个 heredoc 结束标记同为 `WRAP`，抽取逻辑改为取第一个，否则第二段会被追加进第一个文件）；日志断言按 `start: pnpm=` / `start: npm=` 分别取版本，不再用「最后一个 `version=`」 |
| `probe/05` | 缺 `runtime/node/bin/npm` 直接 FAIL |
| `manifest` | `0.7.0` + changelog |

**为什么端到端自检要真跑 `pnpm view`**：前面两条自检只证明「两个 wrapper 各自能跑」，
证明不了「pnpm 会正确转发到我们这份 npm」。这个 bug 正是这样漏过去的 —— 两个包都在、
串起来却是坏的。所以判据必须是**失败的那条命令本身**。

**为什么钉 npm 11.21.1**：node 24 发行版自带的就是 npm 11（engines `^20.17.0 || >=22.9.0`，
与 v24.22.1 相容）；npm 12（latest，`^24.15.0`）虽然也能跑，但刚发布，没必要替 dsh 当小白鼠。

后来真机自检又给了个硬理由：npm 11 对 dsh 固定传的 `--config.fetch-retries` 会打一行

```console
npm warn Unknown cli config "--config.fetch-retries". This will stop working in the next major version of npm.
```

也就是说**升到 npm 12 后这个参数会失效**（dsh 的可控重试就没了）。11 是目前能同时满足
「node 24 兼容」与「认 dsh 的参数」的最后一版。

**复现（手工验证「是不是 npm」）**：把 wrapper 换成会失败的一行，同一条命令必须报错 ——
真机日志里 `verbose cli … /usr/local/bin/npm` 已经是等价证据。

**✅ 0.7.1 真机确认（2026-11-01 17:05）**：界面已能读出 `dsh-free-search` 的描述与
`版本 0.9.26` —— 说明 `pnpm view` 这条转发链彻底通了。失败点前移到安装阶段，见 F30。

---

### F30 插件安装报 `ERR_PNPM_UNEXPECTED_STORE`：profile 的 node_modules 与当前 pnpm 的 store 不一致 ✅（0.7.2 手工生效，0.7.3 起自愈）

**现象**（0.7.1 真机，安装 `dsh-free-search@0.9.26`）：

```console
$ pnpm add dsh-free-search --registry=https://registry.npmmirror.com/   退出码 1
ERR_PNPM_UNEXPECTED_STORE  Unexpected store location

The dependencies at "/vol1/@appshare/dsh/workspace/.dsh-home/profiles/web/node_modules"
are currently linked from the store at "…"。
pnpm now wants to use the store at "/vol1/@appshare/dsh/workspace/.dsh-home/.loc…"
If you want to use the new store location, reinstall your dependencies with "pnpm install"
```

**要点**：这不是「装不上包」，是 pnpm 拒绝在**用别的 store 装出来的** `node_modules` 上继续操作。
pnpm 把依赖以硬链/符号链形式指向 store，换 store 就等于换了一套内容寻址目录，它不敢混用。

**成因（2026-11-01 17:17 拿到完整报错后确认）**：两处 store **布局相同**（都是 `v10`），
差别只是**路径**——旧的那份 `node_modules` 是在 `HOME` 还指向别处时装出来的：

```console
The dependencies at ".../profiles/web/node_modules" are currently linked from the store at
  "/vol1/@appshare/dsh/.pnpm-store/v10"                                   ← 旧，10-29 那次安装留下的
pnpm now wants to use the store at
  ".../.dsh-home/.local/share/pnpm/store/v10"                             ← 现在 HOME=.dsh-home 算出来的
```

**一条被截断的报错走过的弯路**（记下来免得下次重犯）：先前只看到 `…/.loc…` 那半行，
又看到 store 目录下并存 `v10` 与 `v11`，据此推断「跨大版本布局冲突、只能重装」。
实际那个 `v11` 是系统 pnpm 12.5.1 留下的**无关目录**，与这份 profile 没有关系；真正要读的
是报错里被截掉的**前一行**。判据只能来自完整错误文本，不能从目录清单反推。

**修法（不需要停应用、不需要重装）**：把 pnpm 的 store 指回旧路径。`store-dir` 是 pnpm
专有配置，写进 pnpm 自己的全局配置文件（`$HOME/.config/pnpm/rc`），不碰 `.npmrc`，
避免 npm 也去解析一个它不认识的键：

```bash
H=/vol1/@appshare/dsh/workspace/.dsh-home
mkdir -p "$H/.config/pnpm"
printf 'store-dir=%s\n' /vol1/@appshare/dsh/.pnpm-store > "$H/.config/pnpm/rc"
chown -R dsh:dsh "$H/.config/pnpm"
# 验证（以 dsh 身份）：必须打印 /vol1/@appshare/dsh/.pnpm-store/v10
su -s /bin/sh dsh -c "cd / && HOME='$H' PATH=/var/apps/dsh/target/runtime/node/bin:\$PATH pnpm store path"
```

**备选（只有当 dsh 对旧 store 无写权限时）**：那才需要迁移 —— 把 `node_modules` 改名挪开，
以 dsh 身份在新 store 下 `pnpm install` 一次。要点三条：先挪开（否则 pnpm 仍报同一错误）、
必须切到 dsh 用户（否则属主变 root，F26 老坑）、装完核对 `.modules.yaml` 的 `storeDir`。

**真机结果（2026-11-01 18:54）**：按上面手工写完 rc 后

```console
$ su -s /bin/sh dsh -c '… pnpm store path'
/vol1/@appshare/dsh/.pnpm-store/v10
```

即 store 已回旧路径，插件安装恢复。但这只是**这台机器被手工治好**，新装一台仍会重踩。

**0.7.3 起自愈**：`cmd/main` 的 `ensure_pnpm_store_dir()` 在每次 `start` 时（拉起 dsh 之前）：

1. `$DSH_HOME/.config/pnpm/rc` 里已有 `store-dir` → 原样沿用，只在日志里回显（不动用户配置）；
2. 否则读 `profiles/*/node_modules/.modules.yaml` 的 `storeDir`，削掉末尾 `/v10` 这类
   布局版本目录后写进该 rc —— **跟着已装 profile 走**，而不是钉死一个我们以为对的路径
   （硬钉反而会给「用当前默认 store 装出来的 profile」制造同样的冲突）；
3. 一个 profile 都没有 → 什么都不写，日志说明「保持 pnpm 默认」。

日志一行即可判定：`pnpm-store: 沿用已有配置 …` / `pnpm-store: 对齐已有 profile → store-dir=…` /
`pnpm-store: 无已装 profile，保持 pnpm 默认（…）`。三条分支与幂等性都在
`.tmp/t-073.sh` 里跑过。

**真机（2026-11-01 19:18，0.7.3）**：启动日志为
`pnpm-store: 沿用已有配置 /vol1/@appshare/dsh/.pnpm-store` —— 正是分支 1：读到了
0.7.2 时手工写的 rc，并且**没有覆盖**它。分支 2（自动写入）要靠一台没配过的机器，
或删掉 rc 重启一次才能验，留待下次；代码路径与本地用例均已覆盖，不影响结案。


### F31 升级前的数据快照一次都没跑过：备份的是 0.2.0 之前的老路径 ✅（0.7.2 修复，2026-11-01 18:33 真机验证）

**发现方式**（2026-11-01 复盘 807 行 `info.log`）：全文 `grep -c backup` = **0**，
而这段历史里有 **7 次 `upgrade_init`**（0.6.1→0.6.2 … 0.6.9→0.7.1）。

**根因**：`cmd/upgrade_init` 里写死 `DSH_HOME="$PKGVAR/dsh-home"`，随后
`if [ -d "$DSH_HOME" ]` 包住整段备份。0.2.0 起数据已经搬到
`<共享目录>/.dsh-home`（P6），`@appdata/dsh/dsh-home` 早就不存在 —— 条件恒假，
**整段静默跳过**，连一行 WARN 都没有。PLAN §7 写的「快照失败就中止升级」
因此在实现里等于不存在：7 次升级都是在没有退路的情况下做的。

**为什么危险**：`upgrade_callback` 里确实有「新运行时就位失败 → 回滚 `.old`」的兜底，
但那只护程序，不护数据。数据一旦在这次升级里出问题（SQLite 代数变化、profile
被 pnpm 改坏），没有快照就只能认。

**修法（0.7.2）**：

1. 路径改由 `cmd/lib-home` 统一解析（与 `main`、`install_callback` 同一份），
   不再各处硬编码；
2. 快照落到 `$PKGVAR/backups/pre-upgrade-<旧版本>-to-<新版本>-<时间>.tar.gz`，
   **包内保留 `.dsh-home/` 这一层**，恢复时 `tar -xzf … -C <共享目录>` 即可；
3. 只留最近 2 份（每份是整份会话+插件，`profiles/*/node_modules` 可能上百 MB，
   不轮转会把共享目录吃掉一块）；
4. tar `rc≥2`（磁盘满/权限/路径不存在）→ **硬失败中止升级**，数据不动；
   `rc=1`（打包期间有文件变化）→ WARN 放行，但留痕。停机之后理论上不该出现 1，
   不为了一个临时文件把用户卡死；
5. 目录不存在时也写一行日志，不再静默：
   `backup: 跳过——<路径> 不存在（首次安装，或数据目录尚未建立）`。

**验收判据**（下次升级时看 `info.log`）：

```bash
grep -E 'upgrade_init: (backup|home)' /var/apps/dsh/var/info.log | tail -n 5
ls -lh /vol1/@appshare/dsh/backups/       # 0.7.3 起的落点（0.7.2 时是 @appdata，见 F35）
# 现在同时有两份，取最新那份验内容（tar 不接受两个包名当参数）
tar -tzf "$(ls -t /vol1/@appshare/dsh/backups/pre-upgrade-*.tar.gz | head -n1)" | head
# 首行应为 .dsh-home/
```

本地已用假数据跑通：备份/轮转/跳过三条分支都验过（`.tmp/t-home.sh`），
并确认包内有 `.dsh-home/sessions/…`、`.credentials.yaml`、`storages/workspace.json`。

**真机验证（0.7.1 → 0.7.2，2026-11-01 18:33）**：

```
18:33:52 [544194] upgrade_init: backup: ok /vol1/@appdata/dsh/backups/pre-upgrade-0.7.1-to-0.7.2-20261101-183329.tar.gz (486M)
18:34:25 [544782] upgrade_callback: runtime: new runtime in place, dropped .old
18:34:30 [544782] upgrade_callback: ok

$ tar -tzf ….tar.gz | head -3
.dsh-home/
.dsh-home/settings.conf
.dsh-home/profiles/
```

三点都符合设计：快照真落盘（486M，含 `profiles/` 与 `settings.conf`）、包内保留
`.dsh-home/` 顶层目录（恢复时 `-C <共享目录>` 直接铺回去）、升级本身成功。
从 `begin` 到 `callback: ok` 共 78 秒，快照耗时约 56 秒——和 486M 的体量相称。

**遗留**：这份快照落在 `@appdata`，而卸载会清空 `@appdata` 内容（P6），
即「为了回滚而卸载重装」时快照会先被删掉。见 **F35**。


### F32 凭据检查永远打印 `credentials: absent`：同一个路径写错 ✅（0.7.2 修复，2026-11-01 18:34 真机验证）

**现象**：7 次升级，7 次 `upgrade_callback: credentials: absent (首次安装或已清除)`——
但用户一直正常在用 dsh，会话、插件都在。

**根因**：`cmd/upgrade_callback` 查的是 `$PKGVAR/dsh-home/.credentials.yaml`，
和 F31 是同一个失效路径。

**危害不在功能，在判据**：这行日志是「升级保住了 cookie 签名密钥，已配对设备不用
重新登录」的唯一证据。它恒为 absent，等于这条验收**永远无法证伪**——真丢了密钥
也看不出来，只能等用户抱怨要重新配对。

**修法（0.7.2）**：按真实数据目录判断，并把三种情形分开写：

| 情形 | 日志 | 含义 |
|---|---|---|
| `.credentials.yaml` 在 | `credentials: kept（cookie 签名密钥还在…）` | 已配对设备无需重新配对 |
| 无该文件，但有 `sessions/` 或 `storages/workspace.json` | `credentials: 无 .credentials.yaml，但数据目录里已有会话/工作区…` | 正常：key 是在 dsh 界面里配的，或走匿名身份 |
| 目录空/不存在 | `credentials: absent（<路径> 尚未初始化，属正常首装）` | 真·首装 |

同一条日志里还会打印解析出的 `home: <路径>`，以后再写错路径一眼就能看出来。

**真机验证（2026-11-01）**，同一天里有天然对照组：

```
16:10:13 [477439] upgrade_callback: credentials: absent (首次安装或已清除)   ← 0.7.1，旧代码
17:05:49 [512161] upgrade_callback: credentials: absent (首次安装或已清除)   ← 0.7.1，旧代码
18:34:25 [544782] upgrade_callback: home: /vol1/@appshare/dsh/workspace/.dsh-home
18:34:25 [544782] upgrade_callback: credentials: kept（cookie 签名密钥还在，已配对设备无需重新配对）
```

同台设备、同一份数据，旧代码判 `absent`、新代码判 `kept` 并打印出正确路径——
这比单看一行 `kept` 更能证明修的是路径而不是别的。升级后桌面图标直接进 dsh，
未出现配对页，与 `kept` 一致。


### F33 启动日志明文写入完整登录令牌，而这份日志正是要发出去排障的那份 ✅（0.7.2 修复，2026-11-01 18:37 真机验证）

**发现方式**：分析 `info.log` 时注意到，把这份文件发给开发者，就等于把**当时仍然有效**
的入口令牌一起发了出去（该轮 `dsh` 进程还在跑，令牌没过期）。

**两个泄漏点**：

1. `cmd/main` 的 `start: state=…`：只对 URL 里的 `token=` 做了打码，
   **JSON 顶层的 `"token":"<40 位>"` 原样保留** —— 一行里同一个令牌出现两次，
   打掉一处没用。全文共 **23 个唯一令牌**。
2. `dsh` 自己打印的 `dsh web: http://…:3081/?token=<40 位>`：由 `spawn_bg` 的
   `>>"$LOGFILE" 2>&1` 直接追加，**我们控制不了**（24 个唯一令牌）。

再叠加一层：`info.log` 轮转阈值 5 MB，实测 72 KB / 5 天 → 约 300 天才轮转一次，
历史令牌长期留存（重启后旧令牌失效，所以真正危险的是**最后那一行**）。

**修法（0.7.2）**：`start: state=` 加第二条规则
`s#("token": *")[A-Za-z0-9_-]+#\1***#g`，两条正则一起打。已用真实 state 串验证：

```
before: {"url":"…?token=1WFc…","token":"1WFc…","host":…}
after : {"url":"…?token=***","token":"***","host":…}
```

**没修的部分**：`dsh web:` 那一行。改它要动 `spawn_bg` 的输出管道
（`exec > >(sed -u …)`），而 `spawn_bg` 的 pid 记录、进程组回收全靠现在这条
`exec` 链——为了脱敏去动启动路径不划算（F18 就是这类改动翻车的）。
因此改为**文档约束**：RUNBOOK 第 7 步加了脱敏命令，外发前必须过滤。

**判据**：新包启动后 `grep -c '"token":"[A-Za-z0-9_-]\{20,\}' info.log` 应为 0；
`grep -c 'token=[A-Za-z0-9_-]\{20,\}' info.log` 仍会命中 `dsh web:` 那行，属已知残留。

**真机验证（2026-11-01 18:37）**：

```console
$ awk '$0>="2026-11-01 18:33"' /var/apps/dsh/var/info.log | grep -c '"token":"[A-Za-z0-9_-]\{20,\}'
0
```

时间窗卡在升级之后，所以只统计 0.7.2 写的行——旧行里的 23 个令牌仍在（那是历史，
不影响结论）。同日 17:15 的那份日志每条 `start: state=` 都带明文 `"token":"1WFc…"`，
两相对照即知打码确实生效。


### F34 手工启动会算出第二个 var 目录：两套 pidfile 谁也杀不掉谁，3080 被占 2 小时 20 分 ⚠️（0.7.2 已修）

**现场**（2026-10-27，`info.log` 120–167 行）：

```
21:13:31 start: cwd=/var/apps/dsh/cmd/../shares/workspace … home=/var/apps/dsh/cmd/../shares/workspace/.dsh-home
21:13:31 launcher: listening on http://192.168.0.114:3080 (state=/var/apps/dsh/cmd/../var/launcher.json)
21:31:09 stop(launcher): no pidfile, nothing to do          ← 平台这套看的是另一个 var
21:31:14 launcher: listen failed: EADDRINUSE 192.168.0.114:3080
22:07:16 launcher: listen failed: EADDRINUSE 192.168.0.114:3080
23:33:04 launcher: SIGTERM received, closing                ← 手工那个终于被停掉
```

**根因**：`PKGVAR="${TRIM_PKGVAR:-$SELF_DIR/../var}"`。应用中心调用时 `TRIM_PKGVAR`
是 `/vol1/@appdata/dsh`；手工从 `/var/apps/dsh/cmd` 调用时没有这个变量，于是
`mkdir -p` 在**应用目录里**造出一个真的 `var/`，pidfile 与 `launcher.json` 全写在那。
两边各自 `stop` 都只看到自己那套，手工起的跳转器成了孤儿。

**为什么现在才暴露**：0.6.0 之后所有启动都由应用中心发起（`TRIM_PKGVAR` 恒有），
所以没再复现；但根因一直在，任何一次「手工 `cmd/main start` 排障」都会重演。

**修法（0.7.2）**：`TRIM_PKGVAR` 缺省时按平台布局归一 —— 把
`TRIM_APPDEST`（缺省 `$SELF_DIR/../target`，先 `readlink -f`）里的
`/@appcenter/` 换成 `/@appdata/`。实测：

```
/vol1/@appcenter/dsh          -> /vol1/@appdata/dsh
/var/apps/dsh/target (软链)   -> /vol1/@appdata/dsh
```

**判据**：手工 `bash /var/apps/dsh/cmd/main start` 后，
`ls -l /vol1/@appdata/dsh/dsh.pid` 应存在，且 `/var/apps/dsh/var/dsh.pid` **不**出现。


### F35 升级快照放在「卸载就会被清空」的目录里：真要回滚时它先没了 ✅（0.7.3 已修，2026-11-01 真机验收）

**发现方式**：F31 真机验证后顺带看落点——`backup: ok /vol1/@appdata/dsh/backups/…`。
这个路径正是 **P6** 里实测过的「卸载后目录还在、内容被清空」的那个 `@appdata`。

**为什么是问题**：快照的唯一用途是「升级出事了能退回去」，而 RUNBOOK 4.2 的退路
就是**卸载（选保留）→ 重装**。两步一叠加：

1. 用户发现新版本坏了，按 RUNBOOK 4.2 卸载；
2. 卸载清空 `@appdata/dsh` → `backups/pre-upgrade-*.tar.gz` 一起没了；
3. 重装回来，数据已被升级过程改动过，而唯一的旧副本刚被自己删掉。

也就是说，这份快照能防「升级脚本中途失败」，防不了「升级成功但新版本不好用」——
而后者恰恰是用户真正会去回滚的场景。另外 `@appdata` 与 `@appshare` 同在 `/vol1`，
挪位置不产生跨卷拷贝成本。

**修法（0.7.3 已实现）**：

1. `cmd/lib-home` 增加 `dsh_appshare_root()` / `dsh_backup_dir_for()`：以
   `<共享目录里 @appshare 之前的部分>/@appshare/<应用名>` 为「存活根」，
   快照落 `<根>/backups`（本机即 `/vol1/@appshare/dsh/backups`，与 `workspace` 平级，
   不出现在用户的共享目录视图里）；共享目录不在 `@appshare` 下时退回
   `$PKGVAR/backups`，**不会**把 `backups/` 写到 `/vol1` 根上（有本地用例覆盖）；
2. `cmd/upgrade_init` 改用它并打印 `backup-dir:`；升级时把 `@appdata` 里的旧快照
   **一并搬过来**（同卷 `mv` 只是改名），同名已在新的位置则删重复，避免漏搬要到
   回滚那天才发现；
3. RUNBOOK 4.2 补硬约束：**卸载必须选「保留会话、凭据与设置」**，
   选「不保留」会连 `@appshare/dsh` 一起删，快照和会话都救不回来。

**判据**：装 0.7.3 后 `ls /vol1/@appshare/dsh/backups/` 有新的 `pre-upgrade-*.tar.gz`
（且 0.7.2 那份 486M 也在，日志里有「迁移旧快照」）；再走一次「卸载（保留）→ 重装」，
该文件仍在（`@appshare` 权限变 000 由 `install_callback` 自愈，不影响内容）。

本地已验证（`.tmp/t-073.sh`）：落点推导三种布局（`@appshare` / 无共享目录 / 共享目录
不在 `@appshare` 下）、旧快照迁移与同名去重、轮转仍只留 2 份。

**真机验收（2026-11-01 19:18，0.7.2 → 0.7.3）**：

```console
$ ls -lh /vol1/@appshare/dsh/backups/
-rwx------ 1 dsh dsh 486M Nov  1 18:33 pre-upgrade-0.7.1-to-0.7.2-20261101-183329.tar.gz
-rwx------ 1 dsh dsh 486M Nov  1 19:18 pre-upgrade-0.7.2-to-0.7.3-20261101-191752.tar.gz
```

- `upgrade_init: backup: 迁移旧快照 pre-upgrade-0.7.1-to-0.7.2-20261101-183329.tar.gz
  → /vol1/@appshare/dsh/backups`（19:17:52，与 `backup-dir` 同一 PID 569471）；
- 新包 `backup: ok …pre-upgrade-0.7.2-to-0.7.3-20261101-191752.tar.gz (486M)`；
- 旧目录 `@appdata/dsh/backups` 迁移后为空，`rmdir` 已把它移除（`ls -ld` 报不存在）；
- 旧包（18:33 那份）出现在新目录且 **mtime 未被改写**，证明走的是同卷 `mv`（改名），
  不是重新打包——486M 没被真搬一遍；
- `backup-dir:` 打印的路径与数据目录同时给出，以后路径再错一眼能看出来。

唯一没在真机复跑的是「卸载（保留）→ 重装后快照仍在」这一步：`@appshare` 的存活性
由 P6 的既有实测（卸载只把权限改成 000、内容保留）支撑，`install_callback` 已有 000 自愈。
下次真要走卸载重装时顺手 `ls` 一次即可，不作阻塞项。

---

### F37 Web 形态没有 Office 技能，而它的渲染引擎一直在包里 ✅（0.8.1 实现，0.9.1 真机验证）

**发现方式**：顺着「功能在飞牛上能不能用」查形态时发现的——`skill-office` 只出现在
`packages/bundle/sdk-app/cordis.patch.yml`，`base` 和 `web-app` 里都没有；而
`@deepseek-ai/libreoffice-kit` 是 skill-office 的**硬依赖**，会随 `@deepseek-ai/dsh`
一起装进 `node_modules`。Linux 没有原生包，走 `libreoffice-kit-wasm`，解包约 **152MB**。

也就是说：**这 152MB 从 0.7.x 起就一直在我们包里，却没有任何一行配置会挂载它。**
用户既看不到 Office 技能，也享受不到这份体积换来的能力。

**改法**：启动时用 `--patch` 覆盖层插一行 `skill-office`（web 形态原本只叠 base + web-app）。
三个路径必须先验存在：

| 路径 | 缺了会怎样 |
|---|---|
| `runtime/app/node_modules/@deepseek-ai/dsh-skill-office/assets` | 技能资产不全，注册期会抛 |
| `…/@deepseek-ai/libreoffice-kit/lib/cli.js` | 操作类技能没有可执行入口 |
| `runtime/node/bin/node` | Kit 要用自带的 node 跑，系统 node 可能不存在 |

**为什么坚持"缺一就不传 `--patch`"**：`skill-office` 在 `assetRoot`/`cli` 不合法时是
**throw**（`src/index.ts:50-71`），失败的 fiber 会拖垮整个启动。少挂一次只是"没有 Office"，
挂错一次是"应用打不开"——两者代价差一个量级。

**验证判据（真机）**：

1. `probe/05` 出现 `PASS Office 技能资产 / Office 渲染 Kit / Office 技能已挂载`；
2. `grep 'office: ' var/info.log` 最后一行是 `enabled` 且三个路径都在 `@appcenter/dsh/target` 下；
3. 界面里让模型「把这个 xlsx 导出成 PDF」能拿到文件（唯一能证明 wasm 真跑起来的判据）；
4. **中文不能缺字**：导出一份含中文的 docx，用 PDF 阅读器看是不是方块。

> 第 4 条不是多余的：Kit 在 Linux 上走 WASM，而 WASM **只用导入的字体，找不到可用字体
> 时以 `unavailable` 拒绝**。飞牛是最小化 Debian，很可能只有西文字体——那样 PDF 能出、
> 中文缺字。`probe/01` 已加一行报告 `/usr/share/fonts` 里有没有 CJK；真缺就考虑往
> `$DSH_HOME/.fonts` 放一份 Noto Sans CJK SC（约 16MB）。详见
> [HARNESS-FEATURES §3.3](HARNESS-FEATURES.md)。

**真机验证（2026-11-07，0.9.1 / 引擎 0.2.2-rc.1，DEVLOG 37.7–37.8）**：

- `office: enabled`，三个路径齐（`probe/05` 对应三条 PASS）；
- Kit CLI 实测三技能：`recalculate` 公式重算（A3==SUM 缓存值 0 修复为 3，公式保留）、
  `render` xlsx→PNG（144dpi 生成）、`convert` xlsx→真实 PDF 1.7 单页；
- 缺 Arial 仅告警有回退，未出现中文缺字方块；wasm 引擎 v0.1.5 无缺字体阻断。

**未验**：界面侧「让模型把 xlsx 导出成 PDF」的端到端对话流（上述为 Kit CLI 层证明，
引擎与路径已真实可用）。

**没做的**：作者类技能（生成 docx/xlsx/pptx）仍要宿主 Python 库，web 形态没有
`workspace-dependencies` 工具可以借。`probe/01` 已加报告行，先看真机有没有库再决定
要不要在包里带 Python payload（+60–100MB）。见 [HARNESS-FEATURES §3.1](HARNESS-FEATURES.md)。


---

## 三、待验证 / 待办

### T1 0.5.0 打包与真机安装 ✅

0.5.0 的两次 `build.sh full` 都因自测中止（F7、F8）。第三次在 NAS 上跑到 Linux 全量
断言，暴露出 F14（残留运行时导致模式错位，`通过 54 / 失败 1`）。F14 修复后重跑通过，
2026-10-27 21:09 装到真机并验收。

验收标准：`selftest` 全绿 → `install-fpk` 成功 → `05-verify-fpk.sh` 里
`status=0`、3080 由 launcher 占、3081 在听、3080 返 302 带本次令牌、跟随跳转 303/200。

**结果（2026-10-27 21:09，0.5.0 装上真机）**：

```console
probe/05   PASS 33 / WARN 1 / FAIL 0
probe/07   PASS 10 / FAIL 0（判读：auto-ok）
healthz    {"ok":true,"ready":true,"auto":true,"mode":"auto"}
```

- 已装 `version=0.5.0`，`target → /vol1/@appcenter/dsh`，捆绑 dsh `0.2.1-rc.3`、node `v24.22.1`；
- 9 个 `cmd/*` 全部 755（fnpack 没丢执行位）；应用用户 `dsh` uid=971；
- 三处端口一致 3080；launcher 绑 `192.168.0.114:3080`、dsh 绑 `:3081`（仍要求令牌，401）；
- 安装链路耗时（info.log 时间戳）：`install_init` 21:09:29 → `install_callback` 21:09:39
  → `start` 21:09:47 → `ok` 21:09:51，即**解包完成后约 22 秒**进入可用状态。
- F9 外部检验（从另一台机器打）：直连 302；带 `X-Forwarded-For` / `X-Real-IP` /
  `Forwarded` 均为 200 配对页。P0 已关。

剩 1 个 WARN 是 F15（配对密钥 700），已修，下次装包生效。

**0.6.0 打包（2026-10-27 23:44–23:47，NAS 实跑）**：自测 `通过 58 / 跳过 0 / 失败 0`
（0.5.0 是 56，新增双绑 2 条），`dsh 版本校验通过：0.2.1-rc.3`，
产物 `dsh.fpk` **199MB**；包内 `app/` 977M / 63054 个文件。
打包侧唯一异常是 F20（已装版本与共享目录都读不到），已修。

### T2 cookie 跨重启 / 令牌是否一次性 ✅

`probe/07-cookie-persistence.sh` 会重启一次应用来回答两个问题：旧 cookie 还有效吗、
同一 token 能不能连用两次。**令牌若是一次性的**，就得把跳转器改成「先换 cookie 再转发」，
不能再把 token 写进 `Location`。

**结论（2026-10-27）：两个都成立，现有设计可以保留。**

| 问题 | 实测 | 含义 |
|---|---|---|
| 令牌是否一次性 | 连续两次「不带 cookie」点图标，都拿到 302 + 同一个令牌，跟随均 303 | **令牌可复用**，不需要改成「先换 cookie 再转发」 |
| cookie 能否跨重启 | 重启后用重启前的 `dsh` cookie 访问 3081 → 200 | dsh 自己的 cookie 就活得过去，跳转器只是省掉手粘令牌 |

脚本里「第二次点击」用的是**独立、不带 `-b $JAR`** 的 curl，所以 303 不是靠 cookie 蒙过去的，
是真的同一个令牌被接受了第二次。这条区分很重要——若带了 jar，测出来就是假阳性。

### T3 端口写死 3080 🚫 不做（结论，不是待办）

`manifest.service_port` 是**打包期常量**，被平台用于两件事：`checkport` 探测、桌面入口 URL；
`app/ui/config` 里还有一处静态地址。三处必须一致，而前两处只有重打包才能改。

运行期把 `DSH_PORT` 或 launcher 挪到别的端口，平台仍按 3080 探测 → 卡片显示「未运行」、
点图标也打不开。所以「端口可配」不是没做，而是**运行期本来就不该可配**；
撞 3080 只能改 `manifest` 重新打包（或者卸载重装到另一台机器上）。

记录这一条的价值在于：它是一个**看起来该做、实际会制造新故障**的需求，
以后不要再排期。要做也只在构建参数层面做（`build.sh` 生成 manifest 时替换），
不放进应用设置。

### T4 升级不可降级 📋

dsh 的会话/数据库 schema 升级后不保证向下兼容。回滚边界见 PLAN §7.6；实际能不能降级
**没有真机验证过**，不要在重要数据上试。

### T5 大包的安装耗时与磁盘峰值 ⚠️

`install-fpk` 解包 6.3 万文件，`install_init` 只卡了「≥1.5GB 可用」。

**已测（2026-10-27，0.5.0）**：`install_init` 21:09:29 → `install_callback` 21:09:39 →
`start` 21:09:47 → `ok` 21:09:51。解包完成后约 **22 秒**进入可用状态，安装前 `avail=194G`。
比预想的「大包要装很久」快得多，瓶颈不在我们这边。

**2026-10-27 补测**：装完真实占用 **957M / 63056 个文件**（包内 977M，解压后略小）。

**还没测**：解包瞬间的磁盘峰值。`install_init` 卡的是「≥1.5GB 可用」，957M 的实际占用
加解包临时文件（fnpack 会先写 `.tmp` 再改名）留的余量够用，但那只是推断，没有 `df` 峰值数据。

**补充（0.6.0 打包时实测，2026-10-27 23:47）**：包里 `app/` 是 **977M / 63054 个文件**，
而 fnpack 压出来的 **`dsh.fpk` 只有 199M**。之前 README 写的「完整包约 990MB」说的是
**解压后的目录体积**，不是下载体积——文件管理里下载的其实是 199M，别被 990 吓到。

**踩到的测量坑**：`du -sh /var/apps/dsh` 只报 **132K / 17 个文件**，因为
`target`、`var`、`etc` 等都是软链，`du` 默认不跟随。真实内容在 `/vol1/@appcenter/dsh`。
正确的取法：

```bash
du -sh /vol1/@appcenter/dsh                       # 真实占用
find /vol1/@appcenter/dsh -type f | wc -l         # 文件数
```

### T6 双网卡：只有一个地址能进 ✅（0.8.0 实现，0.9.1 真机验证）

**现象（2026-10-28 实测）**：这台 NAS 有 `192.168.0.109`（无线）与 `192.168.0.114`（OVS）。

```
ps  → launcher ... --host 192.168.0.114 --port 3080
ss  → LISTEN 127.0.0.1:3080        (回环，F17 补的)
      LISTEN 192.168.0.114:3080    (探测到的默认路由源地址)
```

`.109` 上没有任何监听，从无线网段访问必然连不上；换 IP（DHCP 续租、切网段）后
还会静默失效到重启应用。

**为什么不能简单「都绑 0.0.0.0」**：dsh 的 web 载体在 load 阶段拒绝通配地址
（`Config.host` 契约，HARNESS-ARCHITECTURE §5.1）。跳转器自己可以绑通配，dsh 不行。

**为什么不能用 HTTP 反代补齐**：cookie 绑定 `hostname:port`，Host/Origin 栅栏在认证之前；
代理改 Host → cookie audience 对不上 → 302 落地即 401。WS（`/api/remote.mux`）还要透传 Upgrade。

**0.8.0 的解法（三个组件，缺一不可）**

| 组件 | 作用 |
|---|---|
| `app/runtime/relay/server.mjs`（新增） | 在**其余本机 IPv4** 上监听 dsh 内部端口，TCP 层原样转发到绑定地址。不解析 HTTP，Host/cookie/Upgrade 全部不变 |
| `cmd/main` | 枚举本机 IPv4（排除 lo/docker/br-/veth 等，**保留 `*-ovs`**）；给 dsh 加 `--trusted-host <ip>:<port>`；起 relay；把地址列表传给跳转器 |
| `app/runtime/launcher/server.mjs` | `--host 0.0.0.0` + `--allow <本机地址>`；302 目标按「请求从哪个地址进来」选，且只认白名单（防 DNS rebinding 把 token 送到外部域名） |

**刻意保留的行为**

- **单网卡不启用**：探测不到第二个地址时不启 relay、不加 `--trusted-host`、跳转器仍只绑一个地址，
  与 0.7.x 完全一致（避免把 docker0 之类接口一起暴露）；
- **relay 不参与 `status`**：它只影响一张网卡，算成异常会让应用中心反复重启整个应用；
- relay 起不来只告警，不阻塞启动。

**验收判据（2026-11-07 于 0.9.1 真机全部满足，DEVLOG 37.7）**

```bash
# 1. 两个地址都能进（都应 200/401，不能是 000）
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.0.114:3080/healthz
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.0.109:3080/healthz
# 2. dsh 真的收到了栅栏放行
tr '\0' ' ' </proc/$(cut -d' ' -f1 /var/apps/dsh/var/dsh.pid)/cmdline | grep -o -- '--trusted-host [^ ]*'
# 3. relay 在跑，且日志有两条 listening
cat /var/apps/dsh/var/relay.pid; grep 'relay:' /var/apps/dsh/var/info.log | tail -4
# 4. 从 .109 的浏览器点图标：应当落到 .109:3081（不是 .114）
```

第 4 条是这次改动的核心验收：**跳转目标必须跟着访问来源走**。

真机结果：healthz 双地址 200（dsh 本体 401，栅栏按 `--trusted-host` 放行）、
`--trusted-host` 出现在 dsh 命令行、relay 两条 listening、.109 入口正确落到 .109:3081。

### T7 未接飞牛统一网关 📋

现在桌面入口是 `http://<浏览器host>:3080/` 直连端口，因此：外网只能用 VPN/Tailscale、
DDNS 与 FN Connect 用不了、双网卡绑错就打不开（T6）。社区成熟方案（dshbase /
`techysy/deepseek-harness-fnos`）走的是 fnOS 统一网关：

- manifest 声明 `microApp`，桌面入口指向 `/app/dsh`；
- 反代经 `target/app.sock`（unix socket）转到 `127.0.0.1:28000`；
- 网关先完成 fnOS 账号登录，再转发身份头（`X-Trim-Userid` / `X-Trim-Isadmin`）。

接入后 launcher 只监听 `127.0.0.1`，`auto` 模式应改成「只信任来自 app.sock 且带网关身份头」
的连接，而不是像 F9 那样一律要求配对。需要先核对
[docs/FNOS-OFFICIAL-DOCS.md](FNOS-OFFICIAL-DOCS.md) 里 `microApp` / socket 的字段规范。

**2026-11-02 补充（对着两个实现读了之后）**

- `YUNXI-fi/DeepSeek-Harness-fnos` 已经跑通这条路：`ui/config` 用 `iframe` +
  `app.sock`，代理进程剥掉 `/app/deepseekharness` 前缀，并且**改写响应体里的
  `/assets`、`/api` 绝对路径**，WebSocket 直接透传。能work，但“改写响应体”是
  上游换资源路径就会坏的耦合。
- 更好的做法是用上游的 `--public-url <带前缀的 URL>`（§5.4 有 e2e）：资源路径与
  302 都按前缀生成，代理只做“收 socket、剥前缀、转 TCP”，**不碰 HTML/JS**。
  这是本项目 T7 的实现路线。
- `techysy` 的 `trusted_hosts.conf` 值得抄思路：把 `fnos.net` / `5ddd.com`
  与用户自定义域名写进 `--trusted-host`，否则网关转发过来的 Host 过不了栅栏。
  但它的落点是 `$DSH_HOME/trusted_hosts.conf`，我们要放 `PKGVAR`，别混进用户数据。

## T12 只出 `x86` 包，ARM 机型装不上 ⚠️

`manifest` 写死 `platform="x86"`，而 `build.sh` 的 node 来自 `NODE_SRC`、依赖用
**本机 npm** 装 —— 产物天然绑定打包机的架构。社区项目都出 x86 / ARM 两套
（`techysy` 还注明 ARM 原生模块要求 glibc ≥ 2.28，且作者未在 ARM 实机自动化测试）。

**已做（0.8.1）**：`build.sh` 在版本检查后按 `uname -m` 校验
`manifest.platform`，不一致直接 `die`；`platform="all"` 也拒绝（fnOS 规范：
含架构二进制时不能用 `all`）。这挡住的是「在 x86 上打出 arm 包」这种静默错误。

**没做**：真正的 ARM 出包。需要在 ARM 机器上跑一次 `bash build.sh`（node 与
node_modules 都就地取），并单独验收 `bwrap`/landlock 可用性——那是 F21 的既有结论，
不能假设两个架构一致。
**2026-11-02 判断修正（读上游源码后）**：以前记的是「dsh 只服务 `/`，路由要留在
`gatewayPrefix` 下 → 接不上」。前半句不成立：

- `--public-url` **可以带路径**（`https://host/apps/dsh`），前端资源与 302 都按请求目录解析；
- 官方 e2e 用例就是「`--public-url` 带前缀 + 前置代理剥前缀」，`/<prefix>/?token=…` 换 cookie 后
  `/<prefix>/api/...` 正常（`apps/cli/tests/profiles/web/tests/public-url.expected.e2e.ts` L244）；
- `--trusted-host` 负责让网关的 authority 过栅栏；`public-url` 只影响公告，不参与鉴权。

所以 T7 的瓶颈**只剩 fnOS 这一侧**：网关要求应用监听 `target/app.sock`，而 dsh 的
webserver 只监听 TCP 字面量。落地路径因此变成「写一层 unix-socket↔TCP 的剥前缀反代」，
而不是「改 dsh」。工作量从"大"降到"中"，且不影响现有 3080 入口（两条路可以并存）。
注意反代必须保留原始 `Host`（cookie audience 绑 hostname:port），并在转发时剥掉
`gatewayPrefix`。

### T8 无进程看护 📋

fnOS 没有 systemd，进程只由应用中心轮询 `cmd/main status` 驱动。`dsh` 本体崩溃后：
launcher 还活着 → `status` 仍返 0，应用中心不会拉起；launcher 死了 → `status` 返 1，
但不保证平台会自动重启。用户看到的是「点图标进不去」。可做的最小方案：launcher
在每次请求时探测内部端口，连续失败则记录并在 `/healthz` 暴露；或由 launcher 兼作看护，
`spawn` dsh 并在退出时重启（需先确认不会与应用中心的 stop 竞争）。

---

### T9 版本跟随：`0.2.2` 线已出，但仍不跟 ⏸（2026-11-02 复核；→ ✅ 11-07 跟到 rc.1）

上游 master 已到 `0.2.2-alpha.2`（2026-10-30 HEAD，距我们分析的 `0.2.1-rc.3` 有 351 个提交）。
npm 实测：`latest = next = 0.2.1-rc.5`，`alpha = 0.2.2-alpha.2` —— **0.2.2 线尚未转 rc**。
本包继续钉 `0.2.1-rc.5`。

> **2026-11-07 更新：前提已满足，跟到 `0.2.2-rc.1`（包 0.9.0）。** npm 实测
> `latest = next = 0.2.2-rc.1`（`alpha = 0.2.2-alpha.3`），GitHub 11-04 发 `v0.2.2-rc.1`。
> 决策与风险记录见 `docs/HARNESS-ARCHITECTURE.md` §11.3.1。下文为当日的原始判断，保留。

**为什么值得单独记一条**：这次复核发现唯一会真正咬人的变化是**引擎声明**。
`0.2.1-rc.5` 的发布包里没有 `engines` 字段，`0.2.2-alpha.2` 声明了 `node >= 24.9.0`。
npm 对 engines 默认**只告警不失败**，所以一旦哪天跟到 0.2.2，
"装得上" 会掩盖 "跑不起来"。已做两件事兜住：

| 位置 | 改动 |
|---|---|
| `fpk/build.sh` | 打包期按数值判 `node -v >= 24.9.0`，低于门槛直接 `die`（不带 node 的骨架包跳过此检查） |
| `probe/05-verify-fpk.sh` | 装机期把"捆绑的 node"从打印改成 PASS/FAIL 判定，包含回退到 `nodejs_v24` 的提示 |

**跟版时要重验的三条**（其余契约见 `docs/HARNESS-ARCHITECTURE.md` §11）：
`--dump-config` 里 `webServer` / `connection` 两行还在 → 启动日志仍是 `dsh web: <url>?token=…`
→ 带 ≥24.9 的 node 重打包并跑 `probe/05`。

**顺带否掉一个诱人的"机会"**：0.2.2 新增的 `sandbox-policy.additionalWritableRoots`
不能解 F23/F24（那是 fnOS 授权 + 选择器导航，不是沙箱写权限），不要为它排期。

---

### T10 应用中心没有「停用」入口 ✅（是 UI 位置，不是缺陷）

**现象**（2026-10-27，0.5.0 装完）：应用卡片上只有「打开」与「卸载」。用户因此
没法在界面里重启应用，「应用中心启动后历史会话还在不在」这条就验证不了。

**候选根因**（待一条命令定性）：

1. 安装后的 manifest 丢了 `ctl_stop=true`。fnOS 会**重写** manifest（源 649B → 装后 942B），
   若没保留这个键，平台就按 `ctl_stop=false` 处理——正是「只有打开/卸载」的表现；
2. 平台把「运行中」判成「已停止」而隐藏停止项（与 F1 同源，F1 已修，但要看 `status` 实际返回）；
3. 该版本把停止入口收进了应用详情页的「⋯」，不在列表卡片上（那就是文档问题，不是缺陷）。

**定性结果（2026-10-27，`diag-1027.txt`）**：

```
ctl_stop = true          ← 候选 1 排除：键在、值对
status   rc=0            ← 候选 2 中「我们的 status」这半排除
两套 workspace → 同一目录（都是 /vol1/@appshare/dsh/workspace）
dsh-home 里 root 所有的文件：1 个（session-e40256df…json，F16 造成）
appcenter-cli 有 start / stop / status
```

所以 `ctl_stop` 与 `cmd/main status` 都没问题，剩最可能的一条是**平台自己探测不到端口**：
launcher 只绑了 `192.168.0.114:3080`，回环上没有监听 → 平台按未运行渲染。已作为 **F17** 修掉
（launcher 双绑），下次装包验证按钮是否出现。

**2026-10-28 二次观测（0.6.0 覆盖安装后，F17 已在包里）**：详情页仍是「打开 + 应用设置」，
无停止项，`运行状态` 显示「运行」，版本已是 `0.6.0`。但按钮组合变了——0.5.0 是
「打开 + 卸载」，现在**卸载不见了**。

这条差异有信息量。飞牛官方在讨论区给过判据：「当前默认行为是，只有 nvidia 这种
无启用/停用的应用，才有卸载按钮」（[tid=48764](https://club.fnnas.com/archiver/?tid-48764.html)）；
另一帖又说操作项藏在详情页**左上角应用图标**里（[tid=4724](https://club.fnnas.com/forum.php?mod=viewthread&tid=4724)，
「点左上角的图标才发现另有洞天」）。据此新的主嫌疑是**入口位置**而非缺陷：
平台已把它当「可启停」应用渲染（卸载让位给应用设置），只是「停用」不在顶部按钮行。

注意飞牛的用词是**停用**，不是「停止」，按字面找会一直找不到。

**00:09 数据回来后，三个原始候选全部落空**：

| 候选 | 状态 | 证据 |
|---|---|---|
| manifest 丢 `ctl_stop` | 排除 | 装后 `ctl_stop = true` |
| 平台把运行中判成已停止 | 排除 | `appcenter-cli status dsh` → `running`、`rc=0` |
| 端口探测不到（回环没监听） | 排除 | `loop=200`；`ss` 见 `127.0.0.1:3080` 与 `192.168.0.114:3080` 同一 pid |

剩下两条路：

1. **UI 入口位置**（主嫌疑）：飞牛把停用/卸载收在详情页**左上角应用图标**里（tid=4724），
   顶部按钮行只放「打开」。待用户点开确认。
2. **渲染规则**：我们的入口是 `type: "url"` + `port: "3080"`；社区同款应用用
   `type: "iframe"` + `gatewaySocket`（走统一网关），并且带 `health.json`。是否只有
   网关型入口才给完整生命周期 UI —— 待验证，验法是抓一个系统自带应用的 `health.json`
   与 `ui/config` 对比。

定性命令（以后同类问题照抄）：

```bash
grep -iE 'ctl_stop|service_port|checkport' /var/apps/dsh/manifest
/var/apps/dsh/cmd/main status; echo "rc=$?"
appcenter-cli status dsh          # 平台的判断，与我们自己的 status 对照
curl -s -o /dev/null -w 'loop=%{http_code}\n' http://127.0.0.1:3080/healthz
curl -s -o /dev/null -w 'lan=%{http_code}\n'  http://192.168.0.114:3080/healthz
```

`probe/05` 自本次起会断言 `ctl_stop=true`，以后每次验收都会直接暴露。

**没有停止按钮时怎么重启**（也适用于验收）：

```bash
appcenter-cli stop dsh            # 1.0.2 有 stop / start / status 三个子命令
appcenter-cli start dsh
su -s /bin/sh -c '/var/apps/dsh/cmd/main start' dsh    # 退路；必须降权，见 F16
```

**00:11 结案（截图铁证）**：停用与卸载都在「打开」按钮**右侧的 ▼ 下拉箭头**里，
点开即见「停用 / 卸载」两项。按钮组是 `打开｜▼｜应用设置`，运维操作全收在下拉里。

所以 T10 从头到尾都不是缺陷：`ctl_stop=true` 一直生效，平台也一直按「可启停」渲染。
三次误判的代价值得记下来——**「按钮不在显眼位置」和「按钮不存在」在截图上长得一模一样**。
以后遇到同类问题，先找 `▼` / `⋯` / 左上角图标，再怀疑 manifest；反过来查会白改一轮代码
（F17 就是这么来的：它本身是有效改进，但并不是这个问题的解）。

### T11 UI 手动安装更高版本能否覆盖升级 ✅

**已知**：命令行这条路彻底不通——`install-fpk` 对已装应用只回 `is installed`（P1），
`install-local` 必踩 10237（P3），`upgrade_*` 钩子在 CLI 路径上永不执行（PLAN §2.7）。

**未知**：应用中心界面里的「手动安装」选一个**更高 version 的同一个 appname**，平台是走
「更新」（触发 `upgrade_init/callback`、替换 `target/`），还是同样静默跳过。这条从没验过，
而它决定以后每次升级要不要先卸载。

**为什么值得验**：卸载再安装有三个成本——必须人工在界面点两次、卸载会把共享目录临时改成
`000`（P6）、一旦包没先下载完就抓不回来。若覆盖安装可行，这些都省掉。

**验法**（0.6.0 包出来后，5 分钟）：

```bash
# 前置：已装 0.5.0 且在运行，0.6.0 的 dsh.fpk 已在手
# 1. 记下当前状态
grep -E '^[[:space:]]*version' /var/apps/dsh/manifest
ls -l --time-style=full-iso /vol1/@appcenter/dsh/runtime/launcher/server.mjs

# 2. 应用中心 → 手动安装 → 选 0.6.0 的包（不要先卸载）
# 3. 装完复核
grep -E '^[[:space:]]*version' /var/apps/dsh/manifest
grep -iE 'upgrade_(init|callback)' /var/apps/dsh/var/info.log
ls -l --time-style=full-iso /vol1/@appcenter/dsh/runtime/launcher/server.mjs
curl -s -o /dev/null -w 'loop=%{http_code}\n' http://127.0.0.1:3080/healthz   # F17 后应为 200
```

**结论（2026-10-28 00:09 实测）：覆盖安装可行，✅ 结案。**

用户在前端「手动安装」直接装 0.6.0（未先卸载），应用中心详情页显示版本 `0.6.0`、
来源「手动安装」、状态「运行」。命令复核：

```
manifest version          = 0.6.0
server.mjs  mtime         = 2026-10-27 23:49:35.738  (dsh:dsh, 19429B)
launcher 进程 pid 3369574 lstart = Tue Oct 27 23:49:45 2026
```

**文件真的换了，进程也是新的**：`server.mjs` 落盘 23:49:35，进程 23:49:45 启动，
晚 10 秒——平台在替换 `target/` 后**自己把进程重启了**（这条以前没验过，很重要：
意味着覆盖安装后不必手动 stop/start，F17 才会在本次直接生效）。

第三条判据（`info.log` 出现 `upgrade_init`）为**空输出**：我们自己的 `upgrade_init/callback`
是空实现、不写日志，平台侧也不记，所以这条无法作为正面证据。前两条已足以定案——
`target/` 换没换看 mtime，进程跑没跑看 lstart，这两条比钩子日志更硬。

**对流程的影响**：以后升级不必「卸载（保留）+ 安装」，直接手动安装更高版本即可，
共享目录与 `dsh-home` 不受影响。RUNBOOK 相应简化。

**判据**：manifest 变成 `0.6.0` **且** `server.mjs` 的 mtime 更新 **且** `info.log` 出现
`upgrade_init` → 覆盖安装可行，文档里的升级流程可以简化；三者任一不成立 → 维持
「卸载（保留）+ 安装」，并按 P1 记下平台行为。

**失败也不亏**：数据在共享目录（P6 实测跨卸载存活），直接按原流程卸载+安装即可，不丢东西。
唯一要防的是「叠文件」——覆盖安装若只叠加不清旧文件，会留下新旧混杂的 `runtime/`
（PLAN §10.1 的 8 / 10 项）。0.5.0→0.6.0 只改外壳、`dsh` 版本没动，这个风险很小。

### T14 dsh Web UI：控制流拒收 >10000 字符文本，composer 崩溃 + 两处 404 ⚠️（2026-11-04 记录）

**环境**：真机 0.7.3（dsh `0.2.1-rc.5`）。三条报错来自浏览器控制台，均在 dsh 包内部，
**与 fpk 封装层无关**——relay 是 TCP 层原样转发、不改字节，Office 补丁只影响技能挂载。

**三条报错与定性**：

1. **主病灶**：`[session-controller] control stream failed: RemoteError: too_big,
   maximum: 10000, path: [6, "text"]`。dsh 服务端对控制流（control stream）载荷做 Zod
   校验：某数组第 7 个元素（index 6）的 `text` 字段超过 **10000 字符上限**被整包拒收。
   典型触发：会话里有一条超长的粘贴文本/超大消息，客户端带着整段会话消息去开控制流。
2. **连锁崩溃**：`TypeError: selector is not a function`，栈在 `useSession →
   UpArrowHistory`，dsh 自报 `slot entry crashed in 'conversation.composer.dock'`。
   是 1 的下游症状——控制流没建立、会话 store 异常，selector 工厂返回了非函数值。
3. **两处 404（噪音为主）**：`/open-in-app/icon/zed` 反复 404——「在编辑器中打开」按
   编辑器名取图标，这版 dsh 没打包 Zed 的图标资源，纯外观问题；`/api/changes.summary?
   sessionId=session-a25d…&seq=2996` 404——轮询「变更摘要」找不到资源，大概率是坏会话
   （症状 1）的下游表现，待换新会话后观察是否消失。

**处置**（用户侧行动，不改代码）：

- 新建会话发短消息验证：正常 → 问题只在坏会话，删掉那条超长消息或弃用该会话即可；
- 新会话也崩 → 上游 bug，带堆栈去 deepseek-harness 提 issue，fpk 侧只能等上游修或升版本（T9）。

**结案判据**：新会话不再出现症状 1/2 且 `changes.summary` 不再 404 → 定性为「单条超长
消息触发上游校验拒收」，记录归档；上游后续版本（≥0.2.2）若放开上限或优雅降级，随 T9
升级时复核后关条目。`icon/zed` 的 404 单独看：菜单图标缺失不影响功能，除非上游修了
图标资源，否则长期挂着也无妨。

---

## 附录：开发机与 NAS 的差异（会咬人的地方）

| 差异 | 后果 | 对策 |
|---|---|---|
| `sed` 的 `\r` 转义支持不同 | 头部解析残留 CR → curl 000（F8） | `tr -d '\r'` + bash 裁空白 |
| Windows 上无进程组语义 | `stop` 杀不掉原生进程 | 自测里 Linux 专属段整段 SKIP |
| Windows 上文件可执行位不保留 | `cmd/*` 打包后不可执行 | `build.sh` 每次 `chmod +x` |
| CRLF | 上传后 `bash` 报 `$'\r': command not found` | `.gitattributes` + `build.sh` 清 CRLF |
| `curl -o /dev/null` 报 error 23 | 请求成功但退出码非 0 | 需要正文时写真实路径，只看码时用 `-w` |
