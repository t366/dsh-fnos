# 上真机 runbook —— 打包 → 手动安装（覆盖升级）→ 验收

给 0.6.5 这一版写的执行清单，之后每个版本都可以照抄（把版本号换掉）。

**三条硬规则，先看再动手**

1. **全部命令必须在 NAS 上跑**。`fnpack` 只装在那台机器，`full` 模式要现场 `npm install`，
   Windows 上打不了包。
2. **升级 = 直接装新包，不用卸载**（T11 已实测）。包一定先落到共享目录再从文件管理下载；
   只有安装被拒或需要回退时才走 4.2 的卸载流程。
3. **只用普通用户**，不要 root。应用本身是 `run-as: package`（专用用户 `dsh`）。

SSH 没开的话：飞牛 → 系统设置 → 终端与 SSH。

> **路径约定**：本文用 `/var/apps/dsh/...`，那是平台给应用挂的**软链入口**。
> 它并非一直存在（2026-10-27 23:44 实测：应用在跑、`/var/apps/dsh` 却没了，见 F20）。
> 一旦它不在，按下面的实体路径替换前缀：
>
> | 软链 | 实体 |
> |---|---|
> | `/var/apps/dsh/target`（代码、runtime） | `/vol1/@appcenter/dsh` |
> | `/var/apps/dsh/var`（`info.log`、pidfile、launcher.json） | `/vol1/@appdata/dsh` |
> | `/var/apps/dsh/etc`（`settings.conf`） | `/vol1/@appconf/dsh` |
> | `/var/apps/dsh/shares/workspace`（共享目录） | `/vol1/@appshare/dsh/workspace` |

---

## 第 0 步　确认已装版本（决定要不要改版本号）

```bash
M=$(ls /var/apps/dsh/manifest /vol1/@appcenter/dsh/manifest 2>/dev/null | head -n1)
echo "manifest=$M"; grep -E '^[[:space:]]*version' "$M"
```

| 输出 | 怎么做 |
|---|---|
| `0.5.0` | 直接进第 1 步：仓库里的 `manifest` 已经是 `0.6.0`，比它高一级，能正常覆盖 |
| `0.6.0`（与 `fpk/manifest` 相同） | 先把 `fpk/manifest` 的 `version` 提到 `0.6.1` 再打包，否则 `build.sh` 会直接 `die`（F12 版本守卫） |
| 其他（`0.2.0` / `0.4.0` …） | 直接进第 1 步 |
| 两处都没有（`manifest=` 为空） | 平台侧状态异常，先跑 `appcenter-cli status dsh` 与 `ls -ld /var/apps /vol1/@appcenter/dsh`，把输出留下再继续 |

顺手确认一下仓库里的版本（第 1 步 `git pull` 之后再跑）：

```bash
grep -E '^version' ~/dsh-fnos/fpk/manifest    # 期望 version="0.6.0"
```

> 为什么必须管：`appcenter-cli install-fpk` 对已装应用只回一句 `is installed`，
> 同版本装上去 `target/` 不会更新。**2026-10-27 之前这条只打警告**，看起来像装成功了。

---

## 第 1 步　拉代码（确认拿到本轮修复）

```bash
cd ~/dsh-fnos
git pull
git log --oneline -1
```

期望最后一行是含 F20 修复的那条提交（与 Gitea 网页上 `main` 的最新一条一致）。
判据以工作区实际内容为准，不用记 commit 号：

```bash
grep '^version' fpk/manifest                      # 必须是 0.6.0
grep -c '@appshare' fpk/build.sh                  # 必须 > 0（F20 的落点修复在里面）
```

不是这样就先别打包——`build.sh` 打的是工作区里的代码，不是远端。

---

## 第 2 步　打包（5–15 分钟；包内 977MB，产出 `dsh.fpk` 约 199MB）

```bash
cd ~/dsh-fnos/fpk
bash build.sh full 2>&1 | tee ~/build-$(grep -E '^version' manifest | cut -d'"' -f2).log
```

`build.sh` 会先跑 `selftest.sh`（约 30 秒），自测不过直接中止。

**必须看到这四行，缺一行就是没过：**

```
通过 58 / 跳过 0 / 失败 0
dsh 版本校验通过：0.2.1-rc.3
app/ 文件数：63054
产物：./dsh.fpk（199M，版本 0.6.0）
```

- Linux 上「跳过」必须是 **0**。开发机（Windows）上的 22 项跳过是权限位、`/proc`、
  进程组这些只能在真机判定的断言，这里会真正执行。
- **通过数只作参考**（本轮 58；每加一条断言就会变），真正的判据是 **`跳过 0 / 失败 0`**。
- `== 版本 ==` 那行必须读到已装版本，形如
  `已安装：0.5.0（读自 /vol1/@appcenter/dsh/manifest）`。**若显示 `<无>`，先别继续**：
  那是 F20 的现场（守卫会空转），先按 F20 的候选路径确认包到底在哪。
- 如果自测开头出现「沙箱内已移除残留的 dsh 运行时」，说明源码树里带着上一次 full
  构建的 `app/runtime/app`（`.gitignore` 的，`git pull` 不会清）。这行是**正常且预期**的
  ——自测已经把它隔离在沙箱外，不影响结论。
- 自测失败时看它列出的「失败项」；确认与本次改动无关才用 `DSH_SKIP_SELFTEST=1` 跳过，
  不要因为想快点过而跳过。
- npm 装不上时先看 `/tmp/dsh-npm-install.log`，再确认 registry 能不能连外网。

---

## 第 3 步　先把包下载到电脑（**必须在安装前**）

飞牛 → 文件管理 → 共享目录 `dsh / workspace` → 下载 `dsh.fpk`（约 199MB）。

`build.sh` 打完会自动把包复制到共享目录，正常会打印：

```
已放到共享目录：/vol1/@appshare/dsh/workspace/dsh.fpk
```

**若它打印「没找到共享目录，包留在 /root/…」（F20 的另一种现场），包在 `/root` 下
文件管理看不到**，手动搬一行即可：

```bash
cp /root/dsh-fnos/fpk/dsh.fpk /vol1/@appshare/dsh/workspace/ && \
  chmod 644 /vol1/@appshare/dsh/workspace/dsh.fpk
```

（`/vol1/@appshare/dsh/workspace` 是共享目录的实体路径，卸载时选「保留数据」它不会被清。）

---

## 第 4 步　手动安装（覆盖升级，不必卸载）

### 4.0　先开一个磁盘采样（T5 只剩这一个缺口，只做这次）

**另开一个 SSH 窗口**，在点安装之前跑起来，装完回来 `Ctrl-C`：

```bash
( while :; do printf '%s %s\n' "$(date '+%T')" "$(df -m /vol1 | awk 'NR==2{print $4}')"; sleep 2; done ) \
  | tee ~/df-peak.log
```

装完算峰值：

```bash
awk 'NF==2 && $2 ~ /^[0-9]+$/ {print $2}' ~/df-peak.log | sort -n | head -1   # 全程最小可用（MB）
```

「安装前可用 − 全程最小可用」= 解包瞬时占用。只关心它有没有逼近 `install_init` 卡的 1.5GB 线。

### 4.1　标准升级：不卸载，直接装新包（T11 已实测可行）

2026-10-27 实测：装 0.6.0 到已装 0.5.0 的设备上，版本号更新、`server.mjs` 被替换、
launcher 进程在文件落盘后 **10 秒**重启（平台自己重启的），`dsh-home` 与共享目录都不受影响。
**所以升级就是装新包，不需要卸载。**

先记两个状态（用来对比）。**注意 `/var/apps/dsh` 可能不存在**（F20 实测过：应用在跑、
软链入口却没了），所以 manifest 要两处都试：

```bash
M=$(ls /var/apps/dsh/manifest /vol1/@appcenter/dsh/manifest 2>/dev/null | head -n1)
echo "manifest=$M"; grep -E '^[[:space:]]*version' "$M"
ls -l --time-style=full-iso /vol1/@appcenter/dsh/runtime/launcher/server.mjs
ps -eo lstart,args | grep 'launcher/server.mjs' | grep -v grep
```

然后应用中心 → **手动安装** → 选新包（**不卸载**）。装完复核：

```bash
M=$(ls /var/apps/dsh/manifest /vol1/@appcenter/dsh/manifest 2>/dev/null | head -n1)
grep -E '^[[:space:]]*version' "$M"                              # 期望新版本号
ls -l --time-style=full-iso /vol1/@appcenter/dsh/runtime/launcher/server.mjs
ps -eo lstart,args | grep 'launcher/server.mjs' | grep -v grep   # lstart 应晚于 mtime
curl -s -o /dev/null -w 'loop=%{http_code}\n' http://127.0.0.1:3080/healthz
```

判据只看两条：**版本号变了** 且 **进程启动时间晚于 `server.mjs` 的 mtime**。
满足即升级成功——比查 `upgrade_init` 日志可靠（我们的钩子是空实现，平台也不记录，那行永远是空的）。

| 现象 | 含义 | 下一步 |
|---|---|---|
| 版本变了 + `lstart` 晚于 mtime + `loop=200` | 覆盖升级成功 | 直接进第 5 步 |
| 版本没变、mtime 没变 | 平台静默跳过 | 走 4.2 卸载+安装，**数据不丢** |
| 版本变了但进程没重启（`lstart` 早于 mtime） | 跑的还是旧代码 | `appcenter-cli stop dsh && appcenter-cli start dsh` |
| 安装直接报错 | 包本身有问题（图标规格、manifest 字段） | 保留当前版本继续跑，先排查包 |

### 4.2　兜底：卸载（选保留）→ 安装

只有在 4.1 被平台拒绝或需要回退时走这里：

1. 应用中心 → dsh → **卸载** → 弹窗选「**保留会话、凭据与设置**」；
2. 应用中心 → **手动安装** → 选刚下载的 `dsh.fpk` → 安装；
   - 向导里 **API Key 留空 = 沿用旧值**，不要为了"干净"重填；
   - 「入口方式」保持默认「点图标直接进入」；
3. 装完点桌面图标，应当直接进 dsh，不出现配对页。
4. 启停入口在**「打开」右侧的 `▼`** 里（「停用 / 卸载」），不在顶部按钮行——看不到不等于没有（T10）。

---

## 第 5 步　验收：结构与入口（只读，不改任何东西）

```bash
bash ~/dsh-fnos/probe/05-verify-fpk.sh 2>&1 | tee ~/p05.log

# 0.6.0 起 launcher 同时在 127.0.0.1 上监听（F17），这一条本身就是验收项：
curl -s -o /dev/null -w 'loop=%{http_code}\n' http://127.0.0.1:3080/healthz

# 局域网绑定地址也应正常（0.5.0 及以前只有这一个监听）：
BIND=$(sed -n 's/^DSH_BIND=//p' /var/apps/dsh/etc/settings.conf | head -n1)
case "$BIND" in ''|auto) BIND=$(sed -n 's/.*bind=\([0-9.]*\).*/\1/p' /var/apps/dsh/var/info.log | tail -n1) ;; esac
curl -s "http://${BIND:-127.0.0.1}:3080/healthz"; echo

# 体积/文件数：/var/apps/dsh 是外壳，target/var/etc 都是软链，du 不跟随。
du -sh /vol1/@appcenter/dsh; find /vol1/@appcenter/dsh -type f | wc -l
```

判据：

- 末尾 `FAIL` 必须为 **0**（`WARN` 允许存在，逐条看是不是已知的那几项）；
- `loop=200` —— 这是 F17 生效的直接证据；若仍是 `000`，说明回环双绑没进包；
- `healthz` 返回 `{"ok":true,"ready":true,"auto":true,"mode":"auto"}`；
- 重点看它报的三处端口是否一致、`cmd/*` 执行位是否 9 个都在。

### 5.1　F9 是否真的生效（在另一台机器上跑）

```bash
# 直连：应当 302（内网自动放行）
curl -s -o /dev/null -w 'direct=%{http_code}\n' http://192.168.0.114:3080/

# 带代理头：应当 200（配对页），不能再是 302
curl -s -o /dev/null -w 'proxied=%{http_code}\n' -H 'X-Forwarded-For: 1.2.3.4' http://192.168.0.114:3080/
```

**升级前实测：两条都是 302。** 说明旧版确实会把「经反代的公网访客」当成内网放行。
升级后必须是 `direct=302` / `proxied=200`，这一条不通过就等于 P0 没修好。

（2026-10-27 装 0.5.0 后实测：`direct=302`、`X-Forwarded-For` / `X-Real-IP` /
`Forwarded` 三种头均 `200`，P0 已关。）

---

### 5.2　F22 默认工作区是否真的建出来了（0.6.6 起）

```bash
H=/vol1/@appshare/dsh/workspace/.dsh-home

# 1) 前置条件：文档目录必须指向共享目录，且不能等于 dsh 的 HOME（等于 HOME 就会被判不可用）
cat "$H/.config/user-dirs.dirs"

# 2) 目录本身
ls -ld /vol1/@appshare/dsh/workspace/deepseek-harness/default-workspace

# 3) 注册表：应出现 defaultWorkspaceId，且原有工作区/会话没被动过
grep -o '"defaultWorkspaceId": *"[^"]*"' "$H/storages/workspace.json"
grep -c '"path"' "$H/storages/workspace.json"
```

判据：

- `XDG_DOCUMENTS_DIR` = `/vol1/@appshare/dsh/workspace`（**不能**是 `.../.dsh-home`）；
- 目录存在，属主 `dsh:AppUsers`；
- `workspace.json` 里有 `defaultWorkspaceId`；工作区条数 = 原有条数 + 1（补登记只在缺默认项时发生）；
- 界面：工作区下拉里出现「默认工作区」并处于勾选态，原来的 `Project` 与旧会话都在。

> 补登记需要一次**真正的重启**（`start` 走到 `spawn` 之前才会执行）。覆盖升级后平台会自己
> 重启进程；如果是手动验证，用 `appcenter-cli stop dsh && appcenter-cli start dsh`。

### 5.3　F23 能不能把任意文件夹当工作区（0.6.7 起）

这一条要看两处：**开关**（设置页有没有那一页）和**实际能不能进去**。

```bash
# 1) 开关：安装后的 manifest 里应为 false
grep -i disable_authorization_path /var/apps/dsh/manifest \
  || grep -i disable_authorization_path /vol1/@appmeta/dsh/manifest

# 2) 平台到底传了哪些授权路径（启动时逐条记下，auth-paths: 前缀）
grep 'auth-paths: ' /var/apps/dsh/var/info.log | tail -n 10
```

界面部分（必须人手点一次，脚本替不了）：

1. 应用中心 → dsh → 设置 → **访问权限** → `+ 添加` → 选一个「我的文件」里的文件夹 →
   权限选 **读写**；
2. 回 dsh → 工作区下拉 → **+ 添加工作区** → 点首屏的 **「可访问目录」** → 选中那个文件夹
   （0.6.8 起；0.6.7 上这条路走不通，见 5.4）；
3. 新工作区里随便让 dsh 建个文件（一句话就够），确认写进去了。

判据：

- 设置里有「访问权限」页（`disable_authorization_path=false`）；没有就是包没换成功；
- 添加后 `info.log` 的 `auth-paths:` 里出现该路径且标「读写」——但**要等下一次重启**才更新，
  所以先看界面能不能用，别为了这行日志去重启（会换代 token）；
- dsh 里能选中并成功写入。若「进不去」，是 ACL 没落到 `dsh` 用户；若「选得中但写失败」，
  多半授权时选成了只读。

### 5.4　F24 选择器里点不点得到授权目录（0.6.8 起）

「加了授权」和「在选择器里点得到」是两件事。dsh 的对话框只从家目录起步，而我们的家目录是
`.dsh-home`，所以 0.6.8 起启动时会把授权目录软链进 `$HOME/可访问目录/`。

```bash
H=/vol1/@appshare/dsh/workspace/.dsh-home
# 挂了哪些（应能看到你授权的文件夹名，指向真实路径）
ls -l "$H/可访问目录"
# 启动时这一步干了什么（跳过/合并/创建都会留一行）
grep 'access-links: ' /var/apps/dsh/var/info.log | tail -n 10
```

界面部分：

1. dsh → 工作区下拉 → **+ 添加工作区** → 首屏应多出 **「可访问目录」**；
2. 点进去 → 选中你的文件夹 → **打开** → 建工作区。

判据：

- 首屏有「可访问目录」，里面有软链指向授权路径；没有就 `grep access-links` 看是不是
  「无授权目录」（平台没传，等下次重启）或「无法创建软链」（权限/文件系统不支持）；
- 日志里 **不该** 出现 `可访问目录/workspace` 这样的链 —— 共享目录包含 `.dsh-home`，
  链上去会递归，代码里按设计跳过；
- 建出的工作区路径是**真实路径**（`/vol1/1000/...`），不是 `可访问目录/xxx` ——
  dsh 入库前会 `realpath`，看到软链路径说明出了偏差。

**0.6.7 上的临时绕法**：对话框右上角有个**铅笔图标**，点开可以手打绝对路径
（如 `/vol1/1000/T366的文件/Project`），回车后点「打开」。

---

## 第 6 步　回归 T2：令牌是否一次性、cookie 能否活过重启

```bash
bash ~/dsh-fnos/probe/07-cookie-persistence.sh 2>&1 | tee ~/p07.log
```

会重启一次应用，约 10 秒不可用，期间不要用浏览器操作。

> **这个探针会改归属，别用 root 跑。** 它内部 `stop`+`start` 一次；root 直接跑会让 dsh
> 以 root 启动、把 `dsh-home` 里的 `-wal` 与会话库写成 root 所有，之后应用中心以 `dsh`
> 身份启动就写不动（症状是「会话少了」，且不报错）。脚本已改成 root 下自动 `su` 到应用用户，
> 并在重启后自检 `find "$HOMEDIR" -user root`；命中会直接报 FAIL 并给出 `chown` 命令。

**0.5.0 已给出结论**（2026-10-27）：令牌**可复用**（连续两次不带 cookie 点图标都 303）、
dsh 的 cookie **跨重启仍有效**（200）。所以「302 把令牌写进 `Location`」的设计成立，
不需要改成「先换 cookie 再转发」。之后每版跑这一步当**回归**：

1. 重启后 GET `3080` 是否 **仍然 302 到新令牌**，跟随能否进到底；
2. 连续第二次点图标是否仍能进（脚本用**不带 cookie 的独立请求**，带 jar 测就是假阳性）；
3. dsh 自己的 cookie 是否跨重启存活。

任一条退回，说明 dsh 上游的令牌语义变了，launcher 要改设计。

---

## 第 7 步　把三份日志发回来

```bash
ls -l ~/build-*.log ~/p05.log ~/p07.log
```

日志里的令牌已由脚本打码，但发之前顺手过一眼：

```bash
sed -E 's/(token=)[^ &]+/\1***/g' ~/p07.log > ~/p07.safe.log
```

---

## 附：失败时先看这三处

```bash
tail -n 50 /var/apps/dsh/var/info.log     # 安装、启停、失败原因都在这
cat /var/apps/dsh/var/launcher.json       # 本轮令牌与绑定地址
ss -ltnp | grep 308                        # 端口有没有被占
```

## 附：`EADDRINUSE 3080` / `appcenter-cli start` 报 10330

**症状**：应用中心弹「入口跳转器启动后立即退出（端口 3080 可能已被占用）」，
或 `appcenter-cli start dsh` 只回 `code 10330`；`var/dsh.pid` 不存在。

**含义**：3080 被**别人的**进程占着——通常是之前以 root 手工 `start` 过
（`probe/07` 老版本会这样）。`kill` 由应用用户执行时对 root 进程是 EPERM，
旧代码静默失败还删 pidfile，于是「pidfile 没了 + status 说没运行 + 端口仍被占」同时成立。

```bash
# 1. 看是谁
ss -ltnp | grep -E ':308[01]'

# 2. 按端口反查 pid 并结束（root 身份执行）
for p in $(ss -ltnp | grep -E ':308[01]' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
  echo "kill $p → $(ps -o user=,comm= -p "$p" 2>/dev/null)"
  kill -TERM "$p"
done
sleep 2
ss -ltnp | grep -E ':308[01]' || echo "端口已释放"

# 3. 让平台自己启动（平台状态才正确）
appcenter-cli start dsh

# 4. 确认身份是 dsh，不是 root
ps -o user=,args= -p "$(cut -d' ' -f1 /var/apps/dsh/var/dsh.pid)" 2>/dev/null || echo "没起来"
```

若第 2 步后端口仍被占，`kill -KILL` 再试；仍不行说明进程在 D 状态（等 IO），
只能重启 NAS。**别用 `cmd/main start` 以 root 手工兜底**——那正是这个问题本身。

完整条目见 [ISSUES.md](ISSUES.md)（F16 / F18），安装/升级界面步骤见 [../fpk/README.md](../fpk/README.md)。
