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
| T1 | 0.5.0 未完成打包与真机安装 | — | ⚠️ | 下一步 |
| T2 | cookie 跨重启 / 令牌是否一次性 | — | ⚠️ | `probe/07` |
| T3 | 端口写死 3080，不可配置 | — | 📋 | 改端口=卸载重装 |
| T4 | 升级不可降级，schema 兼容未验证 | — | 📋 | 见 PLAN §7.6 |
| T5 | 990MB 包的安装耗时与磁盘峰值未测 | — | 📋 | — |
| T6 | 双网卡（.109 无线 / .114 OVS）绑定选择 | — | 📋 | 自动探测默认路由源地址 |

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
「包版本 vs 已装版本」，相同时直接警告，避免又白装一次。

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

---

## 三、待验证 / 待办

### T1 0.5.0 未完成打包与真机安装 ⚠️

0.5.0 的两次 `build.sh full` 都因自测中止（F7、F8）。修复后**尚未重跑**。

验收标准：`selftest` 全绿 → `install-fpk` 成功 → `05-verify-fpk.sh` 里
`status=0`、3080 由 launcher 占、3081 在听、3080 返 302 带本次令牌、跟随跳转 303/200。

### T2 cookie 跨重启 / 令牌是否一次性 ⚠️

`probe/07-cookie-persistence.sh` 会重启一次应用来回答两个问题：旧 cookie 还有效吗、
同一 token 能不能连用两次。**令牌若是一次性的**，就得把跳转器改成「先换 cookie 再转发」，
不能再把 token 写进 `Location`。

### T3 端口写死 3080 📋

`manifest.service_port`、`app/ui/config`、向导默认值、跳转器参数四处都写死 3080。
改端口目前等于卸载重装。要做成可配，得同时改这四处并在 `install_callback` 里落盘。

### T4 升级不可降级 📋

dsh 的会话/数据库 schema 升级后不保证向下兼容。回滚边界见 PLAN §7.6；实际能不能降级
**没有真机验证过**，不要在重要数据上试。

### T5 990MB 包的安装耗时与磁盘峰值未测 📋

`install-fpk` 解包 6.3 万文件，`install_init` 只卡了「≥1.5GB 可用」。真实耗时、
临时空间峰值都没测过。

### T6 双网卡绑定选择 📋

这台 NAS 有 `192.168.0.109`（无线）与 `192.168.0.114`（OVS）。桌面入口用的是**你访问飞牛
时浏览器里的 host**，而 dsh 只能绑一个地址——绑错就点不开。当前策略是自动探测默认路由源地址。

---

## 附录：开发机与 NAS 的差异（会咬人的地方）

| 差异 | 后果 | 对策 |
|---|---|---|
| `sed` 的 `\r` 转义支持不同 | 头部解析残留 CR → curl 000（F8） | `tr -d '\r'` + bash 裁空白 |
| Windows 上无进程组语义 | `stop` 杀不掉原生进程 | 自测里 Linux 专属段整段 SKIP |
| Windows 上文件可执行位不保留 | `cmd/*` 打包后不可执行 | `build.sh` 每次 `chmod +x` |
| CRLF | 上传后 `bash` 报 `$'\r': command not found` | `.gitattributes` + `build.sh` 清 CRLF |
| `curl -o /dev/null` 报 error 23 | 请求成功但退出码非 0 | 需要正文时写真实路径，只看码时用 `-w` |
