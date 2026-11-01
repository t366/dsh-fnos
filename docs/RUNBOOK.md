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
| 比 `fpk/manifest` 里的版本**低** | 直接进第 1 步，能正常覆盖升级 |
| 与 `fpk/manifest` **相同** | 先把 `fpk/manifest` 的 `version` 提一级再打包，否则 `build.sh` 会直接 `die`（F12 版本守卫） |
| 其他（更老的 `0.2.0` / `0.4.0` …） | 直接进第 1 步 |
| 两处都没有（`manifest=` 为空） | 平台侧状态异常，先跑 `appcenter-cli status dsh` 与 `ls -ld /var/apps /vol1/@appcenter/dsh`，把输出留下再继续 |

顺手确认一下仓库里的版本（第 1 步 `git pull` 之后再跑）：

```bash
grep -E '^version' ~/dsh-fnos/fpk/manifest    # 应与 README「包版本」一致（本文写于 0.7.3）
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
grep '^version' fpk/manifest                      # 与 README「包版本」一致（本文写于 0.7.3）
grep -c '@appshare' fpk/build.sh                  # 必须 > 0（F20 的落点修复在里面）
```

不是这样就先别打包——`build.sh` 打的是工作区里的代码，不是远端。

> **`git pull` 报 `local changes … would be overwritten`？**
> 多半不是有人改了代码，而是上一次打包干的：`build.sh` 里的 `chmod +x cmd/*` 把
> `cmd/lib-home`（以及 `cmd/*.mjs`）加成可执行，而仓库里记的是 `644` —— git 把 mode 位
> 也算改动，于是「本地有改动 + 远端也改了这个文件」就被拒。先确认：
>
> ```bash
> git diff -- fpk/cmd/lib-home     # 只有 old mode / new mode、没有内容 hunk，就是它
> ```
>
> 内容没变就直接丢掉 mode 变化再拉；真手改过就先存一份 patch。
>
> ```bash
> git checkout -- fpk/cmd/lib-home fpk/cmd/*.mjs
> git pull
> ```
>
> 0.7.3 起 `build.sh` 对这两个文件显式 `chmod a-x`，不会再把工作区弄脏。

---

## 第 2 步　打包（5–15 分钟；包内约 997MB，产出 `dsh.fpk` 约 205MB）

```bash
cd ~/dsh-fnos/fpk
bash build.sh full 2>&1 | tee ~/build-$(grep -E '^version' manifest | cut -d'"' -f2).log
```

`build.sh` 会先跑 `selftest.sh`（约 30 秒），自测不过直接中止。

**必须看到这几行，缺一行就是没过：**

```
跳过 0 / 失败 0
dsh 版本校验通过：0.2.1-rc.5
pnpm 自检通过：10.34.9（app/runtime/pnpm 23M）
npm 自检通过：11.21.1（app/runtime/npm 20M）
端到端自检通过：pnpm view lodash version -> 4.18.1
app/ 文件数：6.6 万左右
产物：./dsh.fpk（约 208M，版本 0.7.3）
```

- **`dsh 版本校验通过：0.2.1-rc.5` 必须是 rc.5**：这行是回读装进来的 `package.json` 得到的，
  不是打印请求值。若显示 rc.3，说明跑的还是改之前那份 `build.sh`（或 `DSH_VERSION` 被环境覆盖）。

- Linux 上「跳过」必须是 **0**。开发机（Windows）上的 26 项跳过是权限位、`/proc`、
  进程组这些只能在真机判定的断言，这里会真正执行。
- **通过数只作参考**（每加一条断言就会变），真正的判据是 **`跳过 0 / 失败 0`**。
- **`pnpm 自检通过` 与 `npm 自检通过` 都必须出现**（0.7.0 起）：前者证明 pnpm 装进了 runtime
  且 wrapper 能跑，后者证明 pnpm 转发时的目标也备齐了。分别 `die` 时看
  `/tmp/dsh-npm-pnpm.log` 与 `/tmp/dsh-npm-npm.log`。
- **`端到端自检通过：pnpm view …` 是最关键的一行**（0.7.0 起）：它真的执行了用户在界面上
  点「安装」时的那条命令（pnpm 会把 `view` 转发给 npm）。这行 `die` 说明两个包管理器串不起来，
  0.6.9 的 F29 就是这样漏到真机的 —— 两个包都在、各自都能跑，唯独中间的转发是坏的。
  没有外网时可用 `DSH_SKIP_NETCHECK=1` 跳过，但那样这层保障就没了。
- 这行前面**可能多一行 `npm warn Unknown cli config "--config.fetch-retries"`**：npm 11 对
  dsh 固定传的这个参数会告警（走 stderr，不影响结果）。判据取的是「最后一行像版本号的」，
  所以带不带这行告警都算通过；只要没有版本号才 `die`。
- `== 版本 ==` 那行必须读到已装版本，形如
  `已安装：0.6.8（读自 /vol1/@appcenter/dsh/manifest）`。**若显示 `<无>`，先别继续**：
  那是 F20 的现场（守卫会空转），先按 F20 的候选路径确认包到底在哪。
- 如果自测开头出现「沙箱内已移除残留的 dsh 运行时」，说明源码树里带着上一次 full
  构建的 `app/runtime/app`（`.gitignore` 的，`git pull` 不会清）。这行是**正常且预期**的
  ——自测已经把它隔离在沙箱外，不影响结论。
- 自测失败时看它列出的「失败项」；确认与本次改动无关才用 `DSH_SKIP_SELFTEST=1` 跳过，
  不要因为想快点过而跳过。
- npm 装不上时先看 `/tmp/dsh-npm-install.log`（dsh）、`/tmp/dsh-npm-pnpm.log`（pnpm）、
  `/tmp/dsh-npm-npm.log`（npm），再确认 registry 能不能连外网。

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

| 现象 | 含义 | 下一步 |
|---|---|---|
| 版本变了 + `lstart` 晚于 mtime + `loop=200` | 覆盖升级成功 | 直接进第 5 步 |
| 版本没变、mtime 没变 | 平台静默跳过 | 走 4.2 卸载+安装，**数据不丢** |
| 版本变了但进程没重启（`lstart` 早于 mtime） | 跑的还是旧代码 | `appcenter-cli stop dsh && appcenter-cli start dsh` |
| 安装直接报错 | 包本身有问题（图标规格、manifest 字段） | 保留当前版本继续跑，先排查包 |

### 4.1.1　升级钩子的三行判据（0.7.2 起必看）

0.6.0 之后 `upgrade_init/callback` 不再是空实现，日志里能直接看到升级做了什么。
0.7.2 起有三行是**验收项**，缺任何一行都说明对应环节没跑：

```bash
grep -E 'upgrade_(init|callback): (home|backup|credentials)' /var/apps/dsh/var/info.log | tail -n 6
```

| 期望行 | 含义 | 缺了说明 |
|---|---|---|
| `backup-dir: /vol1/@appshare/dsh/backups（数据目录 …）` | 快照落点（0.7.3 起） | 还指向 `@appdata` → 跑的是 0.7.2（F35，卸载会连快照一起删） |
| `backup: ok …/backups/pre-upgrade-<旧>-to-<新>-<时间>.tar.gz (xxM)` | 升级前快照已落盘 | 0.7.2 之前这是**静默跳过**的（F31）；0.7.2 起失败会直接中止升级 |
| `backup: 迁移旧快照 … → /vol1/@appshare/dsh/backups` | 把 `@appdata` 里的旧包搬到新落点 | 只在首次从 0.7.2 升级时出现一次，没出现也不影响升级 |
| `home: /vol1/@appshare/dsh/workspace/.dsh-home` | 钩子解析到的数据目录 | 路径不对 → 快照与凭据检查都在看别处（F31/F32 的根因） |
| `credentials: kept（cookie 签名密钥还在…）` | 已配对设备不用重新配对 | 写成 `absent` 而用户明明在用 → 路径又错了 |

插件装不上时，先看 `main` 启动时对 pnpm store 的判断（0.7.3 起）：

```bash
grep 'pnpm-store:' /var/apps/dsh/var/info.log | tail -n 3
# 沿用已有配置 …            → 你（或我们）已配过，没动它
# 对齐已有 profile → …       → 按 profiles 的实际 store 自动写好了（F30 自愈）
# 无已装 profile，保持默认   → 还没装过插件，正常
```

快照只留最近 2 份，随时可以这样确认与恢复：

```bash
ls -lh /vol1/@appshare/dsh/backups/
tar -tzf /vol1/@appshare/dsh/backups/pre-upgrade-*.tar.gz | head   # 首行应为 .dsh-home/

# 真要回滚数据（先停应用）：
appcenter-cli stop dsh
tar -xzf /vol1/@appshare/dsh/backups/pre-upgrade-<旧>-to-<新>-<时间>.tar.gz \
    -C /vol1/@appshare/dsh/workspace
appcenter-cli start dsh
```

> **落点的来历（F35）**：0.7.2 把快照写进 `@appdata/dsh/backups`，而卸载会清空
> `@appdata` 的内容（P6）——偏偏「为了回滚而卸载重装」才是唯一会用到快照的场景。
> **0.7.3 起落点改到 `/vol1/@appshare/dsh/backups/`**（与 `workspace` 平级，卸载只改
> 权限、内容保留），升级时会把 `@appdata` 里的旧快照自动搬过来，日志打
> `backup: 迁移旧快照 … →`。
>
> 还在 0.7.2 上、又打算卸载重装的，先手动拷一份出来：
> ```bash
> mkdir -p /vol1/1000/dsh-rollback && cp /vol1/@appdata/dsh/backups/pre-upgrade-*.tar.gz /vol1/1000/dsh-rollback/
> ```

### 4.2　兜底：卸载（选保留）→ 安装

只有在 4.1 被平台拒绝或需要回退时走这里：

1. 应用中心 → dsh → **卸载** → 弹窗选「**保留会话、凭据与设置**」；
   - 这一项**不能选错**：选「不保留」会连 `/vol1/@appshare/dsh` 一起删，
     会话、凭据、以及 `/vol1/@appshare/dsh/backups/` 里的升级快照全部不可恢复（P6 / F35）；
   - 0.7.2 及更早装的，快照还在 `@appdata/dsh/backups/`，卸载前先拷到 `/vol1/1000/` 下
     （命令见 4.1 末尾的提示框）；
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

### 5.5　授权目录 dsh 到底读不读得了（0.6.8 起）

「平台说授权成功」和「dsh 真的能读」也是两件事 —— 2026-10-29 真机上就撞到：目录授权了、
工作区也建出来了，可 agent 逐个文件报「无法读取（owner:nobody, mode 0000）」。
原因是那批文件本身没给 `dsh` 任何权限位，而我们旧版日志是用 **root** 探的（root 绕过 mode 位），
所以写着「读写」，把人带偏了。

```bash
# 现在日志是按 dsh 身份探的：应看到「读写」，或者明确指出读不了
grep 'auth-paths: ' /var/apps/dsh/var/info.log | tail -n 10
# 权限实况：属主、mode、有没有给 dsh 的 ACL
P=/vol1/1000/Project
ls -ld "$P"; find "$P" -maxdepth 1 -printf '%U:%G %m %p\n' 2>/dev/null | head -10
getfacl -p "$P" 2>/dev/null | head -15
id dsh
# 直接以 dsh 身份试一次（这两条不写任何东西）
runuser -u dsh -- ls "$P" 2>&1 | head -5
runuser -u dsh -- head -c 40 "$P/README.md" 2>&1 | head -3
```

判据与处理（2026-10-29 真机第二次取证的补充）：

- 日志写「读写」+ `runuser` 也读得动 → 正常，问题不在权限；
- 日志写「读不了…如 xxx（nobody:nogroup 0000）」→ **文件本身没权限**。两个选择：
  1. 文件管理里对那个文件夹重新设权限，勾上「应用到子文件夹和文件」；
  2. 由管理员（root）修正属主，**先看清属主该是谁**：
     `id 1000`（FNOS 的存储空间里 `/vol1/1000` 通常就是该用户），
     再 `chown -R 1000:1000 /vol1/1000/Project`。
     这一步会覆盖现有 ACL，跑之前先 `getfacl` 留一份。
- 日志写「dsh 进不去」→ **不要用 `ls -ld` / `getfacl` 下结论**。2026-10-29 真机实测：
  `/vol1/1000/Project` 是 `d---------`、`getfacl` 只有 `user::---`/`group::---`/`other::---`
  三条、**没有任何扩展条目**，可属主 `T366` 照样 `ls` 和读 `984:979 600` 的 README，
  `dsh` 也照样跑通了 `readdir` —— 这台机器上显然还有一层 mode / POSIX ACL 之外的授权在放行
  （形态待查）。所以「0000 谁都进不去」这个直觉在这里是错的，够不够权限**只能实测**：

  ```bash
  runuser -u dsh -- ls   "$P" 2>&1 | head -5    # 能列 = 目录的 r 有
  runuser -u dsh -- head -c 40 "$P/README.md"   # 能读 = 文件层也给了
  ```

  两个结果分开看：**能列不能读**说明目录没问题、是**文件/子目录没给 dsh 权限**
  （真机上就是 `984:979 600` 的网页文件和 `0:0 700` 的 `.dsh`/`deepseek-harness`/`dsh-run`
  这批）；两个都不行才是目录层的事。

**别用 `setfacl`**（2026-10-29 01:03 实测否定）：`setfacl -R -m u:dsh:rwX` **确实写进去了**，
`getfacl -p README.md` 能看到 `user:dsh:rw-` + `mask::rw-` —— POSIX 语义下必须放行 ——
可 `runuser -u dsh -- head` 照样 EACCES。这台机器上这个目录的判定**不吃 POSIX ACL**，
（`css/` 那次"通了"也不能当证据，可能本来就能进）。所以别再在它上面刷 ACL 了。

走 mode 语义，一次到位（先留底）：

```bash
P=/vol1/1000/Project
getfacl -R -p "$P" > ~/acl-backup-project-$(date +%F-%H%M).txt
chown -R 1000:1001 "$P"                # 1000=T366, 1001=Users（用 id 1000 确认）
chmod -R u+rwX,go+rX "$P"              # 目录 755 / 文件 644
runuser -u dsh -- head -c 40 "$P/README.md"
```

`go+rX` 是关键：`dsh` **不在 `Users` 组**（`groups=901(AppUsers),966(dsh)`），靠 `other` 的
读位最省事，不用再纠结 ACL 和组。`chown` 会把 `984:979`（= `dsh-qddev`，另一套包的旧应用
用户）和 `0:0` 的残骸一并归一，所以**只对确定属于你的目录用**；共享文件夹请走文件管理界面
的「应用到子文件夹和文件」。

顺手一个线索：目录里出现 `.local`、`.dsh`、`deepseek-harness`、`dsh-run` 且属主是 `0:0`
mode `700` —— 这四样正是 dsh 首次启动会在 `$HOME` 下建的东西（`.local` 的 XDG 目录、`.dsh`
配置、`deepseek-harness` 默认工作区父目录、`dsh-run` 运行目录），说明曾经有 root 身份、
把 `HOME` 指到那个目录跑过一次 dsh。默认工作区因此被建在了 `deepseek-harness/default-workspace`
这种 **`0:0 700`** 的路径下，换成 `dsh` 用户运行时进不去（这次跟 mode 0000 无关，是 root 独占的
`700`），前端就报 `defaultWorkspace.failed`（「缺少默认工作区」）。确认里面没有你要留的东西后，
把这一批**移走**（`mv` 到备份目录，别直接 `rm`），再重启应用，让它按应用用户的 HOME 重建。

> 别用应用启动脚本去自动 `chown` 用户文件：那既越界，又会把 FNOS 的 ACL 冲掉。
> 应用只负责**说清楚**是权限问题，修数据是用户/管理员的事。

### 5.6　插件能不能装（0.7.0 起，F28 + F29）

**先看启动日志有没有把两个包管理器都交给 dsh**：

```bash
grep -E 'start: (pnpm|npm)=' /var/apps/dsh/var/info.log | tail -n 4
```

期望（0.7.0，两条都要有）：

```
… start: pnpm=/var/apps/dsh/target/runtime/node/bin/pnpm version=10.34.9（已前置到 PATH）
… start: npm=/var/apps/dsh/target/runtime/node/bin/npm version=11.21.1（pnpm 的 view/add 转发目标）
```

只有 `WARN: 缺少 runtime/node/bin/pnpm` → 装的还是 0.6.8 或更早；
只差 npm 那条（有 `WARN: 缺少 runtime/node/bin/npm`）→ 装的是 0.6.9，
插件仍会报 `npm error Class extends value undefined`（F29）。两种情况都是「装 0.7.1 的包」。

**再确认两个 wrapper 真能跑**（不必等界面报错）：

```bash
cd / && PATH=/var/apps/dsh/target/runtime/node/bin:$PATH pnpm --version
cd / && PATH=/var/apps/dsh/target/runtime/node/bin:$PATH npm --version
```

分别是 `10.34.9` 与 `11.21.1`。**还要看那条会转发的那步**（这一步才真正验 F29）：

```bash
cd /tmp && PATH=/var/apps/dsh/target/runtime/node/bin:$PATH \
  pnpm view lodash version --registry=https://registry.npmmirror.com/ --config.fetch-retries=0
```

输出 `4.18.1` 一类的版本号就对了；报 `npm error Class extends value undefined` 说明 npm 还是
系统那份（wrapper 没进 PATH，或包不对）。

**再在界面里试一次**：插件 → 添加插件 → 输入包名（例如 `billion-context`）→ 应能读到版本号
并开始下载，而不是 `spawn pnpm ENOENT`。

装完插件后列表若没变化，**重启应用**：

```bash
appcenter-cli stop dsh && appcenter-cli start dsh
```

插件装在 `.dsh-home` 下的 profile 子目录，重启才会重新加载 bundle。直接看落了什么：

```bash
ls -l /vol1/@appshare/dsh/workspace/.dsh-home/profiles 2>/dev/null
grep -n '"dependencies"' -A8 /vol1/@appshare/dsh/workspace/.dsh-home/profiles/*/package.json 2>/dev/null
```

**失败时按报错分流**：

| 报错 | 含义 | 动作 |
|---|---|---|
| `spawn pnpm ENOENT` | 包里没有 pnpm（0.6.8 及更早） | 装 0.7.1 |
| `npm error Class extends value undefined` + `.npm/_logs/…debug-0.log` | pnpm 转发给系统 npm 10.9.3，与自带 node 24 不兼容（F29） | 装 0.7.1；应急见下方 |
| `ERR_PNPM_FETCH_404` / `404` | 包名或版本不存在 | 核对 npm 上的名字（`curl -s https://registry.npmmirror.com/<名字> \| head -c 200`） |
| `ETIMEDOUT` / `ENETUNREACH` | NAS 出不了外网 | 换 registry 或给 NAS 配代理 |
| `EACCES` / `EPERM` | 数据目录写不进去 | 见 5.5；插件目录必须在 `.dsh-home` 下 |
| `unreviewed build scripts` / `allowBuilds` | pnpm 10 默认禁止依赖跑 install 脚本 | 按提示把包名加进 `<profile>/pnpm-workspace.yaml` 的 `allowBuilds`，再重试 |

**F29 的应急补丁**（不想等 0.7.1 打包，NAS 上以 root 做，30 秒）：

```bash
R=/var/apps/dsh/target/runtime
/var/apps/nodejs_v24/target/bin/npm install --prefix "$R/npm" npm@11.21.1
cat > "$R/node/bin/npm" <<'EOF'
#!/bin/sh
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/node" "$here/../../npm/node_modules/npm/bin/npm-cli.js" "$@"
EOF
chmod +x "$R/node/bin/npm"
cd / && PATH="$R/node/bin:$PATH" pnpm view lodash version --registry=https://registry.npmmirror.com/
appcenter-cli stop dsh && appcenter-cli start dsh
```

（注意 wrapper 里是**两级** `../../npm`：`$here` 已经是 `runtime/node/bin`。）

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

## 第 7 步　把日志发回来

```bash
ls -l ~/build-*.log ~/p05.log ~/p07.log
```

### 7.1　三份日志分别在哪

| 日志 | 位置 | 里面有什么 |
|---|---|---|
| 应用日志 | `/var/apps/dsh/var/info.log`（实体 `/vol1/@appdata/dsh/info.log`，>5MB 轮转到 `.1`） | 钩子日志 + launcher + **dsh 本体的 stdout/stderr**；启停失败、插件安装报错都在这 |
| 插件安装 | `.dsh-home/.npm/_logs/*debug-0.log`（`$H` 见下） | pnpm 转发给 npm 之后的完整堆栈 |
| 打包 | `~/build-<版本>.log`、`/tmp/dsh-npm-*.log` | 只在构建机上 |

dsh 自己不写文本日志：会话记录在 `$H/sessions/`，界面「导出会话」生成的
`dsh-session-session-<uuid>.zip` 落到浏览器下载目录，不是 NAS 上的固定路径。

### 7.2　发之前必须脱敏

**`info.log` 里有当前仍然有效的登录令牌**，拿到它就能直接进 dsh。脚本只给探针日志
打过码，`info.log` 没有（`dsh web: …?token=` 那行由 dsh 子进程直写，我们改不了）：

```bash
H=/vol1/@appshare/dsh/workspace/.dsh-home
sed -E -e 's/(token=)[A-Za-z0-9_-]+/\1***/g' \
       -e 's/("token": *")[A-Za-z0-9_-]+/\1***/g' \
       /var/apps/dsh/var/info.log > ~/info.safe.log
sed -E 's/(token=)[^ &]+/\1***/g' ~/p07.log > ~/p07.safe.log

# 确认没有残留（两条都应为 0）
grep -c 'token=[A-Za-z0-9_-]\{20,\}' ~/info.safe.log
grep -c '"token":"[A-Za-z0-9_-]\{20,\}' ~/info.safe.log
```

> 0.7.2 起 `start: state=` 那行已经把 JSON 里的 token 也打了码，但 `dsh web:` 那行
> 永远是明文（子进程 stdout 直写）。所以**不要跳过这一步**。
> 万一原文件已经外发过，重启一次应用即可让旧令牌失效（每次启动都换新令牌）。


---

## 附：失败时先看这几处

```bash
tail -n 50 /var/apps/dsh/var/info.log     # 安装、启停、失败原因、升级钩子都在这
ls -lh /vol1/@appshare/dsh/backups/        # 升级前快照（0.7.3 起；0.7.2 的旧包在 @appdata，升级时自动搬）
cat /var/apps/dsh/var/launcher.json       # 本轮令牌与绑定地址
ss -ltnp | grep 308                       # 端口有没有被占
```

> `info.log` 和 `launcher.json` **都含当前有效的登录令牌**。贴到对话里之前先按 7.2 脱敏。

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
