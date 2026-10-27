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
| F17 | 入口只绑局域网地址，平台探测不到「在跑」 | 缺陷 | ⚠️ | `launcher` 回环双绑；**待装包验证按钮** |
| F18 | stop 报成功但进程还活着 → start 只回 10330 | 缺陷 | ✅ | `cmd/main` `is_alive()` 复核 + 失败上报 |
| T1 | 0.5.0 打包与真机安装 | — | ✅ | `probe/05` 33 PASS / 1 WARN / 0 FAIL |
| T2 | cookie 跨重启 / 令牌是否一次性 | — | ✅ | `probe/07` 10 PASS：令牌可复用、cookie 跨重启存活 |
| T3 | 端口写死 3080，不可配置 | — | 📋 | 改端口=卸载重装 |
| T4 | 升级不可降级，schema 兼容未验证 | — | 📋 | 见 PLAN §7.6 |
| T5 | 解包瞬间磁盘峰值未测（耗时与占用已测） | — | ⚠️ | 下次安装时轮询 `df` |
| T6 | 双网卡（.109 无线 / .114 OVS）绑定选择 | — | 📋 | 自动探测默认路由源地址 |
| T7 | 未接飞牛统一网关，外网/DDNS 无解 | — | 📋 | 见下文 |
| T8 | 无进程看护，dsh 崩了不会自动拉起 | — | 📋 | 见下文 |
| T10 | 应用中心只有「打开 / 卸载」，没有停止 | — | ⚠️ | 根因指向 F17，**待装包验证** |

---

## 当前剩余问题（按优先级）

> 截至 2026-10-27 23:34，代码 `ec1b0b1`、已装包 `0.5.0`。只列**还没关闭**的项；已修条目见第二节。

### P0 现在就要处理：服务是停着的

F16 → F18 的连锁结果：root 起的跳转器仍占 `192.168.0.114:3080`，`appcenter-cli stop`
杀不掉它却删了 pidfile，于是三个状态同时成立——**平台认为已停、端口仍被占、`start` 回 10330**。

处置见 [RUNBOOK「EADDRINUSE 3080」](RUNBOOK.md)：按端口反查 pid → `kill` →（端口释放后）
`appcenter-cli start dsh`。起来后 `ps -o user=` 必须是 `dsh`，不是 `root`。
**别用 root 手工 `cmd/main start` 应急**，那正是这条链的起点。

### P1 已修、等下一次装包才生效

打包前必须把 `manifest` 的 `version` 从 `0.5.0` 提到 **`0.6.0`**——`build.sh` 现在遇到
同版本会直接 `die`（F12）。一次打包把这四项全带上：

| 项 | 生效后应看到 |
|---|---|
| F17 回环双绑 | 卡片出现停止按钮；`curl 127.0.0.1:3080/healthz` 返回 200 |
| F18 stop 复核 | 停不掉时对话框里有原因，不再只有一个 10330 |
| F15 密钥自愈 | `probe/05` 的 `WARN 配对密钥权限是 700` 消失 |
| `probe/05` 新断言 | `ctl_stop` 丢失、两套 workspace 分裂、dsh-home 混入 root 文件，都会直接 FAIL |

（`probe/07` 的降权自检 F16 属探针侧，`git pull` 即生效，不必等装包。）

### P2 待验证：判据已写好，缺的只是真机跑一次

| 项 | 判据 | 前置 |
|---|---|---|
| T10 停止按钮 | 卡片上出现「停止」 | 0.6.0 装包 |
| 历史会话是否还在 | 由**平台**启动后，侧栏旧会话仍在 | 0.6.0 装包 + 用应用中心启动 |
| T5 解包峰值 | 安装时轮询 `df`，峰值不超 1.5GB 阈值余量 | 0.6.0 安装 |
| T6 双网卡 | 从 `.109` 与 `.114` 两侧都能打开入口 | 无 |
| T4 能否降级 | 快照回滚后旧 dsh 读不读得动新 schema | 无（高风险，可长期搁置） |

### P3 要做但还没动手

| 项 | 收益 | 代价 |
|---|---|---|
| **T7 统一网关** | 一次解决外网 / DDNS / FN Connect / 双网卡，并套上 fnOS 登录鉴权 | 大：manifest `microApp`、`app.sock` 反代、`auto` 判据重写 |
| T8 进程看护 | dsh 崩了能自愈 | 中：要先理清与应用中心 stop 的竞争 |
| 瘦身 990MB → 约 120MB | 安装更快、占用减半 | 中：`install_dep_apps: nodejs_v24` + 去 bundled node |
| 插件能力 | 「一切皆插件」才用得起来 | 中：`bin/dsh` 包装 + 官方 plugin market bundle |
| T3 端口可配 | 避免 3080 冲突 | 小，但 manifest / 向导 / UI / 跳转器四处联动 |
| ARM 包 | 覆盖更多机型 | 交叉构建 + 真机验证 |

**排序上的一个判断**：如果确定要做 T7，F17 的回环双绑只是过渡措施——统一网关下 launcher
本来就该只监听 `127.0.0.1`，那时「平台探测不到」和「双网卡绑错」会一起消失。所以 T7 要么
尽早做，要么明确不做；不要先为 T6 写一套网卡探测，再被 T7 推翻。

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

**修法**：读到时顺手自愈——若 `mode & 0o077` 非零则 `chmod 600`（失败忽略）。

**验证**：语法检查 + 自测 `30 通过 / 22 跳过 / 0 失败`，pair 段 8 项全绿。
真机要等下一次装包才生效（当前装的 0.5.0 是修复前打的）。

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
**真机待确认**：装上新包后应用中心是否出现停止按钮。若仍然没有，说明平台不是靠回环探测，
要往「第三方应用不出启停」这个方向查。

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

### T3 端口写死 3080 📋

`manifest.service_port`、`app/ui/config`、向导默认值、跳转器参数四处都写死 3080。
改端口目前等于卸载重装。要做成可配，得同时改这四处并在 `install_callback` 里落盘。

### T4 升级不可降级 📋

dsh 的会话/数据库 schema 升级后不保证向下兼容。回滚边界见 PLAN §7.6；实际能不能降级
**没有真机验证过**，不要在重要数据上试。

### T5 990MB 包的安装耗时与磁盘峰值 ⚠️

`install-fpk` 解包 6.3 万文件，`install_init` 只卡了「≥1.5GB 可用」。

**已测（2026-10-27，0.5.0）**：`install_init` 21:09:29 → `install_callback` 21:09:39 →
`start` 21:09:47 → `ok` 21:09:51。解包完成后约 **22 秒**进入可用状态，安装前 `avail=194G`。
比预想的「990MB 要装很久」快得多，瓶颈不在我们这边。

**2026-10-27 补测**：装完真实占用 **957M / 63056 个文件**（包 990MB，解压后略小）。

**还没测**：解包瞬间的磁盘峰值。`install_init` 卡的是「≥1.5GB 可用」，957M 的实际占用
加解包临时文件（fnpack 会先写 `.tmp` 再改名）留的余量够用，但那只是推断，没有 `df` 峰值数据。

**踩到的测量坑**：`du -sh /var/apps/dsh` 只报 **132K / 17 个文件**，因为
`target`、`var`、`etc` 等都是软链，`du` 默认不跟随。真实内容在 `/vol1/@appcenter/dsh`。
正确的取法：

```bash
du -sh /vol1/@appcenter/dsh                       # 真实占用
find /vol1/@appcenter/dsh -type f | wc -l         # 文件数
```

### T10 应用中心只有「打开 / 卸载」，没有停止 ⚠️

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

### T6 双网卡绑定选择 📋

这台 NAS 有 `192.168.0.109`（无线）与 `192.168.0.114`（OVS）。桌面入口用的是**你访问飞牛
时浏览器里的 host**，而 dsh 只能绑一个地址——绑错就点不开。当前策略是自动探测默认路由源地址。

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

### T8 无进程看护 📋

fnOS 没有 systemd，进程只由应用中心轮询 `cmd/main status` 驱动。`dsh` 本体崩溃后：
launcher 还活着 → `status` 仍返 0，应用中心不会拉起；launcher 死了 → `status` 返 1，
但不保证平台会自动重启。用户看到的是「点图标进不去」。可做的最小方案：launcher
在每次请求时探测内部端口，连续失败则记录并在 `/healthz` 暴露；或由 launcher 兼作看护，
`spawn` dsh 并在退出时重启（需先确认不会与应用中心的 stop 竞争）。

---

## 附录：开发机与 NAS 的差异（会咬人的地方）

| 差异 | 后果 | 对策 |
|---|---|---|
| `sed` 的 `\r` 转义支持不同 | 头部解析残留 CR → curl 000（F8） | `tr -d '\r'` + bash 裁空白 |
| Windows 上无进程组语义 | `stop` 杀不掉原生进程 | 自测里 Linux 专属段整段 SKIP |
| Windows 上文件可执行位不保留 | `cmd/*` 打包后不可执行 | `build.sh` 每次 `chmod +x` |
| CRLF | 上传后 `bash` 报 `$'\r': command not found` | `.gitattributes` + `build.sh` 清 CRLF |
| `curl -o /dev/null` 报 error 23 | 请求成功但退出码非 0 | 需要正文时写真实路径，只看码时用 `-w` |
