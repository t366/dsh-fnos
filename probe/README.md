# dsh on fnOS —— 真机评估与 M1 安装验收（五步）

脚本都是**幂等、可重复跑、不写系统目录**的。阶段一/四/五完全只读；阶段二只在自己指定的临时目录里装东西，结束后进程会被停掉。

## 第 0 步：把脚本传上去

Windows 侧（PowerShell / Git Bash 都可以）：

```bash
scp E:/Project2/dsh-fnos/probe/0*.sh <用户>@<NAS地址>:~/dsh-fnos/probe/
```

如果 NAS 没开 SSH：fnOS 的「系统设置 → 终端与 SSH」里可以打开。**只用普通用户登录，不要 root。**

## 第 1 步：只读体检（1 分钟，不要 root）

```bash
bash ~/01-preflight.sh ~/
```

它会打一份 markdown 报告到 `~/dsh-preflight-<时间>.md`，同时在终端打印。看最后的汇总表：

- 全 `OK` → 直接进第 2 步。
- 有 `FAIL` → 把报告发我，先解决（常见是 Landlock 未启用、`/vol*` 带 `noexec`）。
- 有 `WARN` → 可以继续，但要记下来（例如内存 4GB，意味着后面绝不能在这台机器上做 git 源码构建）。

## 第 2 步：冒烟（约 10 分钟，取决于下载速度）

```bash
bash ~/02-smoke-dsh.sh
```

它做这些事：

1. **优先复用 fnOS 自带的 `nodejs_v24`**（版本 ≥ 24.9 才用），找不到才下载官方 Node
2. 把 `@deepseek-ai/dsh` 装进 `~/dsh-probe/app`
3. **按 dsh 真实使用的参数**探沙箱：`bwrap` 优先、`landlock-run` 兜底；root 身份下额外用 `setpriv` **降权到 nobody 再测一遍 bwrap**
4. `--dump-config` 验证 `web` profile 能合成插件树（不启动服务）
5. 用**默认路由的局域网 IP** 真正启动 `dsh web`，抓启动 URL
6. 验证：带 token 能进、跟随重定向 200、**不带 cookie 应 401**、**伪造 Host 应 403**、Host 等于监听地址应放行
7. 记录启动耗时、RSS / 线程数、`DSH_HOME` 实际落位，然后停掉进程

可选参数：

```bash
BIND_IP=127.0.0.1 bash ~/02-smoke-dsh.sh   # 只在本机回环验证（最保守）
BIND_IP=192.168.0.114 bash ~/02-smoke-dsh.sh  # 指定网卡（双地址环境推荐显式指定）
PORT=3099 bash ~/02-smoke-dsh.sh           # 换端口
PKG=@deepseek-ai/dsh@0.2.2-rc.1 bash ~/02-smoke-dsh.sh  # 钉版本（默认钉与 build.sh 一致的版本，npm 的 latest 标签落后多个 RC）
NODE_BIN=/var/apps/nodejs_v24/.../node bash ~/02-smoke-dsh.sh  # 指定运行时
WORKDIR=/vol1/dsh-probe bash ~/02-smoke-dsh.sh   # 装到数据卷
CLEAN=1 bash ~/02-smoke-dsh.sh             # 跑完删掉临时目录
```

⚠️ 第 5 步会在局域网里短暂暴露一个未加防护的 dsh 实例（带随机 token）。脚本 90 秒内会停掉它；如果你介意，用 `BIND_IP=127.0.0.1`。

## 第 3 步：常驻跑起来，从浏览器真进去（M0 收尾）

冒烟只是 curl 验证。M0 的出口是"**另一台设备的浏览器能进 UI 并跑完一个回合**"，所以需要一个常驻进程。

```bash
# 1) 配 API Key（否则模型列表是空的，没法真对话）
printf '%s' 'sk-你的key' > ~/dsh-probe/apikey && chmod 600 ~/dsh-probe/apikey

# 2) 启动
cd ~/dsh-fnos/probe && bash 03-run-dsh.sh start

# 3) 把打印出来的 URL 拿到另一台设备（电脑/手机）的浏览器打开
```

`03-run-dsh.sh` 不是一个方便脚本，它是 **fpk 里 `cmd/main` 的逻辑原型**：

| 它做的事 | 为什么现在就要验证 |
|---|---|
| 启动前**等待绑定地址出现**（最多 60s） | 这台机器默认路由在 OVS 网桥、无线另有地址；开机时网络可能晚于应用就绪，`--host` 会直接 `EADDRNOTAVAIL` |
| **`setsid` 建独立进程组**，`stop` 用 `kill -TERM -PGID` | dsh 会 fork pty/shell 子进程，不整组收就成孤儿 |
| `status` 只用 `kill -0` + `/proc` 校验，返回 **0=运行 / 3=未运行** | 直接对齐 fnOS 的 `cmd/main` 契约，以后整段搬过去 |
| 运行时解析 **bundled → system → 明确报错** | §3.1 的决定：不静默降级 |
| 先读 `.credentials.yaml` 优先级，再退回 `DEEPSEEK_API_KEY` | 与 dsh 凭据服务的优先级一致（文件 > 启动环境 > `.env`） |

```bash
bash 03-run-dsh.sh url      # 打印当前带 token 的 URL
bash 03-run-dsh.sh status   # 0=运行 3=未运行
bash 03-run-dsh.sh stop
```

⚠️ `start` 打印的 URL **等于完整 shell 权限**。在另一台设备打开一次、换到 cookie 之后，`~/dsh-probe/dsh-url.txt`（600）就可以删掉。

## 第 4 步：飞牛的 Node 到底怎么用（1 分钟，只读，随时可跑）

```bash
bash ~/04-probe-node.sh ~/
```

官方口径是「隔离安装、不进 PATH」，但**真实路径随卷号变化**（`/vol{N}/@appcenter/nodejs_v{X}/bin`），而 `/var/apps/nodejs_v24` 只是另一个视图。这份报告回答：

- `node` 到底是实体还是符号链接，解析到哪个卷
- `npm prefix` / `npm root -g` 落在哪 → **全局装的包会不会随应用升级被清掉**
- PATH 是靠什么注入的（`/etc/profile.d`？还是根本没有）
- 有没有别的应用在引用它（`install_dep_apps` 的实际用法）
- 降权到 `nobody` 后还能不能执行

这直接决定 fpk 里该写死路径、还是必须启动时探测。

## 第 5 步：打包（1 条命令）、前端安装、验收（M1）

NAS 上（`build.sh` 已经内置 selftest，失败会中止）：

```bash
cd ~/dsh-fnos && git pull
cd fpk && bash build.sh full
```

打完包会自动复制到应用共享目录 `dsh/workspace`。**安装全部在飞牛界面完成**：

1. 电脑上打开 文件管理 → 共享目录 `dsh / workspace`，先下载 `dsh.fpk`（卸载后该目录权限会被临时改成 000）；
2. 应用中心 → dsh → 卸载，选「保留会话、凭据与设置」；
3. 应用中心 → 手动安装 → 选这个 fpk。

然后（可选，只读验收）：

```bash
bash ~/dsh-fnos/probe/05-verify-fpk.sh        # 结构 + 入口端到端（含自动跳转）
bash ~/dsh-fnos/probe/07-cookie-persistence.sh # 重启后点图标还能不能进，会重启一次应用
```

`selftest.sh` 会伪造一套 `TRIM_*` 环境，在临时目录里完整跑一遍 `install_init → install_callback → start → status → HTTP → 重复 start → stop → 重复 stop`，外加跳转器的自动进入/配对/限速。Linux 上全跑，Windows 开发机上会跳过进程语义相关的项。

`05-verify-fpk.sh` **不改任何东西**，只核对「应用中心不会报错、但会静默失败」的那几项：

| 检查 | 为什么必须看 |
|---|---|
| `target/runtime/stub/server.mjs` 是否存在 | 验证包内 `app/` 是否原样落进 `target/`；不落，`cmd/main` 直接找不到入口 |
| 9 个 `cmd/*` 的执行位 | `fnpack` 若打成 644，应用中心一调用就失败 |
| 三处端口（manifest / 桌面入口 / settings.conf） | 不一致的症状是「能启动但点图标打不开」，且 `checkport` 检查错端口 |
| `dsh` 用户与 `var/dsh-home` 归属 | 决定进程有没有写权限 |
| `share/workspace` 共享目录 | 没生效时工作目录会静默回落到 `var/dsh-home`，用户找不到文件 |
| `status` 退出码 + 端口监听 + HTTP | 契约是否 0/3，绑的到底是哪个 IP |

退出码：全通过为 0，有 FAIL 为 1，可直接串在脚本里。

## 把什么发回来

两份报告 + 三个日志（如果阶段二有失败）：

- `~/dsh-preflight-*.md`
- `~/dsh-probe/dsh-smoke-*.md`
- `~/dsh-probe/dsh-run.log`（启动日志，最关键的诊断素材）
- `~/dsh-probe/dump-config.yml`
- `~/dsh-probe/npm-install.log`

**发之前请检查**：`dsh-run.log` 里可能有带 `?token=` 的完整 URL，把 token 部分涂掉再发。

```bash
sed -E 's/(token=)[A-Za-z0-9_-]+/\1***/g' ~/dsh-probe/dsh-run.log > ~/dsh-run.safe.log
```

## 这五个脚本要回答的问题

| 脚本 | 要回答 |
|---|---|
| 01 | 这台机器能不能跑 dsh？（架构、glibc、内存、noexec、网络、端口、fnOS 应用体系） |
| 01 | Landlock 到底有没有激活？非特权 user namespace 开不开？（决定 bwrap 能不能为普通用户工作） |
| 01 | **fnOS 自带的 `nodejs_v24` 够不够新？**（够新就能省掉一整份自带运行时） |
| 02 | `@deepseek-ai/dsh` 在这台机器上装得上吗？体积多大？ |
| 02 | **bwrap 在 root 下能过、降到 nobody 还能过吗？**（fpk 应用不是 root，这是最容易漏的假阳性） |
| 02 | 换系统 Node 会不会炸（原生模块 ABI）？→ 决定选 R1 还是 R1b |
| 02 | `--host <局域网IP>` 真的能起、真的能从别的设备访问吗？ |
| 02 | 401 / 403 两道门是不是真的在生效（**安全模型是否成立**） |
| 02 | 冷启动要多久、占多少内存？`DSH_HOME` 落在哪？ |
| 04 | 飞牛的 node 在哪、是不是软链、全局包落在哪（**决定能不能复用、怎么复用**） |
| 05 | 装出来的东西对不对：`app/`→`target/` 映射、`cmd/*` 执行位、三处端口、目录归属、共享目录 |

## v2 修掉的三个坑（第一轮真机暴露）

1. **报告首行多出一个 `81`**：数组变量名叫 `LINES`，而它是 **bash 内置的终端行数变量**，`declare -a` 把值当成了第 0 个元素，导致整份报告错位。已改名 `RPT`。
2. **DeepSeek API 返回 401 被判 WARN**：`case` 里写了 `2*|3*|401|403`，缺通配符，`"401 0.24s"` 匹配不上。已修成 `401*|403*`——401 是"可达且需鉴权"，属正常。
3. **Node 版本用 `case` 通配比较**：`v24.8.1` 会被误判为满足 `24.9`。已改成点分比较（`sort -V`），并验证 `24.19.0 ≥ 24.9.0` 成立。

