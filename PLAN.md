# 把 DeepSeek Harness 做成飞牛 fnOS 原生应用（无 Docker）——技术方案

状态：研究稿 **v0.8（M1 自测通过；打包前按官方规范校正 build/manifest）**　日期：2026-10-27

> 本文是**方案与决策依据**。想知道「现在做到哪一步」「踩过哪些坑」，看
> [README.md](README.md) / [docs/DEVLOG.md](docs/DEVLOG.md) / [docs/ISSUES.md](docs/ISSUES.md)；
> 本文只负责解释「为什么这么设计」。

---

## 0. 结论摘要

| 问题 | 结论 |
|---|---|
| 能不能不用 Docker？ | **能**。fpk 原生应用完整支持，进程由应用中心的 `cmd/main start\|stop\|status` 驱动，**没有 systemd 集成** |
| 最大的技术障碍是什么？ | ~~Node 版本~~ → ~~沙箱~~ → **两项均已实测排除**（node 24.22.1 可用；bwrap 在 root 与 `nobody` 下都通过）。剩下的障碍是工程性的：① **866MB / 6.3 万文件**的安装体验；② **token URL 等价于 shell 权限**；③ **升级后不可降级** |
| 局域网访问怎么做？ | dsh 官方支持：`dsh --profile web --host <局域网IP> --no-open`。**不能用 `0.0.0.0`**（架构层拒绝），必须填具体网卡 IP |
| 有没有认证？ | 有：进程启动时随机 mint 一个 **launch token**，浏览器用它换一枚 **30 天**的 host-only cookie；全站 API 还要过 **Host/Origin 栅栏** |
| 推荐路线 | **R1：自带 Node 24 + `npm i @deepseek-ai/dsh` 产物**。系统的 `nodejs_v24`（实测 24.22.1）虽可用，但只省 13% 体积、换来"依赖一个可被卸载的商店应用"，不划算（§3.1） |
| 更新怎么做？ | **只走 fpk 覆盖升级**，不做应用内自更新；升级前强制快照，且**回滚有明确边界**（见 §7） |
| 最大风险 | **token URL 等价于完整 shell 权限**；其次是**升级后不可降级**的会话格式/数据库 schema |
| 能不能不用 fpk、直接 git？ | 能，但那是「自建服务」而非「应用中心应用」；这台机器 **11.7GB 内存 / 8 核**，反而让 git 构建从"不可行"变成"可行但慢"（见附录 A） |
| 真机到哪一步了？ | **阶段一 19 OK / 0 FAIL，阶段二 11 OK / 0 FAIL —— dsh 已在 FNOS 上跑通**。沙箱在非 root 下实测可用，启动 3 秒 / RSS 406MB。详见 §2.3、§2.4 |

---

## 1. 目标与非目标

**目标**
1. 在飞牛 fnOS 上以应用中心标准方式安装/启动/停止/**升级**。
2. 局域网内其他设备浏览器可访问完整 Web UI。
3. 全程不依赖 Docker / Docker Compose。
4. 以专用低权限用户运行，尽量不碰 root。

**非目标（v1 明确不做）**
- 公网/远程访问（FN Connect、DDNS、内网穿透）。
- 多用户隔离。dsh 是**单身份单进程**模型（一个 `$DSH_HOME`、一个 cookie 签名密钥、一个 token）。
- 应用商店正式上架（先自签 `appcenter-cli install-fpk`）。
- 在 NAS 上安装第三方 dsh 插件（`dsh plugin` 依赖 pnpm + 网络）。
- **应用内自更新 dsh**（见 §7.5，会破坏版本管理与回滚）。

---

## 2. 事实核查

### 2.1 dsh 侧（读仓库源码与文档确认）

| 事实 | 出处 | 影响 |
|---|---|---|
| `dsh --profile web --host <IP>` 是官方支持的局域网绑定方式，示例里直接写 `--host 10.0.0.7` | `docs/cli-help.md` L184-206 | 局域网方案成立 |
| **通配地址被拒绝**：`0.0.0.0` 及 IPv4-mapped 形式在 load 阶段报错 | `docs/subsystems/web-server.md` L102、`packages/client/connection/README.md` L47 | 必须探测具体 IP |
| Host 校验接受三种：loopback、**监听器自己的绑定 IP**（任意端口）、`trustedHosts` | `packages/client/connection/README.md` L47 | 直连 IP 时**无需** `--trusted-host` |
| Origin 必须与 Host 同 authority，`sec-fetch-site: cross-site` 一律拒绝 | 同上 | 反向代理必须保留原始 `Host` |
| 认证 = launch token 换 cookie，只在 `GET /` 与 `/connect` 接受 query token | 同上 L41 | 第一个请求必须是带 token 的 `GET /` |
| cookie 绑定「规范化 hostname + 端口」，`HttpOnly`、`SameSite=Strict`、默认 30 天 | 同上 L43 | **登录一次管 30 天** |
| TLS 由 webserver 原生支持，此时 cookie 带 `Secure` | `docs/user/guide/public-deployments.zh.md` L33 | 可选项 |
| WebSocket 用于 `/api/remote.mux` | 同上 L34 | **任何前置代理必须转发 Upgrade** |
| 沙箱 Linux 后端链是 **`['bwrap','landlock']`**：bwrap **优先**，Landlock 兜底；bwrap 走**功能性探测**（真的起一个进程），不是看命令在不在 | `packages/sandbox/sandbox-local/src/index.ts` L156-161、`profiles.ts` L15-22 | bwrap 存在但探测失败会**静默降级**到 Landlock，权限语义不同，必须分别测 |
| bwrap 探测参数固定为 `--ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true` | `packages/sandbox/sandbox-local/src/profiles.ts` L15 | 自测时必须复刻这组参数，否则结论不可比 |
| `landlock-run` 由 `@deepseek-ai/node-addon-system` 经 npm 分发（不是系统包） | `packages/sandbox/sandbox-local/src/index.ts` L34 | 自带运行时路线下它一定存在；系统 Node 路线下也不缺 |
| **`@deepseek-ai/dsh` 已在 npm 公开发布**：`latest`=`0.2.1-rc.2`、`next`=`0.2.1-rc.4`，MIT，`bin` → `lib/bin.js` | registry.npmjs.org（2026-10-27 查） | **不需要从源码构建**，npm 路线成立；但 `latest` 落后于仓库（rc.3） |
| 发布包**没有声明 `engines`**，npm 不会因 Node 版本不足而拦截 | 同上 | 版本不满足只会在**运行时**炸，所以必须靠冒烟脚本判定 |
| **会话格式当前 V4**，`SESSION_FORMAT_VERSION` 是唯一权威；已发布格式 `dsh-v0.2.0-rc.2` 为 V4 | `docs/session-format-status.md` | 升级可能 bump 代数 |
| **会话世代只增不改**：可以新增相邻迁移包，但永不移动/覆盖/删除已提交世代；**旧版本不提供 fallback 也不支持降级** | `AGENTS.md`、`docs/architecture.md` L126 | 升级后旧版本读不了新会话 |
| SQLite 存储 `user_version` 不匹配时**硬失败**（`incompatible with this build`），非降级兼容 | `packages/storage/storage-sqlite/src/schema.ts` L82 | 数据库也单向前进 |
| 存在单文件可执行构建（`@yao-pkg/pkg --sea`，内嵌 node24，约 174MB），但闭包按 `sdk` profile 定义 | `.agents/notes/implemented/architecture/2026-07-10-...md` | v2 瘦身选项 |
| 每个外部可感知的破坏性变更都会进 `docs/upgrade-guide/<version>/` | `AGENTS.md`、`docs/upgrade-guide/` | 升级前可据此判断风险 |

### 2.2 fnOS 侧（官方文档已逐页核实，规范底本见 `docs/FNOS-OFFICIAL-DOCS.md`）

> 官方站提供 `https://developer.fnnas.com/llms.txt`（AI 索引）与 `llms-full.txt`（全文）；`sitemap.xml` 是 404。查规范先拉 `llms.txt`，不要猜路径——我此前猜的 `package-structure` / `desktop-entry` / `ui` 三个页面都不存在。

| 事实 | 影响 |
|---|---|
| 基于 Debian，内核 6.12.18+，支持 x86_64 / ARM64 | glibc 2.36+、Landlock ABI ≥ 5，满足要求 |
| `cmd/main` 单参数 `start\|stop\|status`；`status` 返回 **0=运行 / 3=未运行 / 1=失败**，被**定期轮询** | 必须轻量、无副作用 |
| `start` **必须自己后台化并立即返回**（`&` + PID 文件） | 不能前台跑 |
| **无 systemd**，开机由应用中心拉起 | 不要写 .service |
| `config/privilege`：`"run-as": "package"` 创建专用用户/组；`root` 模式仅限官方合作企业 | 天然低权限 |
| `config/resource`：`api-scope` / `data-share` / `usr-local-linker` / `docker-project`（不填 docker 项） | 共享目录靠 `data-share` |
| 端口只在 `manifest` 的 `service_port`（**仅一个**）+ `checkport` | 双端口方案受限，见 §5 |
| `install_dep_apps` 可声明运行时依赖，`:` 分隔多个、**从右到左安装启用**、`>` 约束最低版本、**依赖不递归**。**官方 `runtime` 页明确推荐这条路**（`install_dep_apps=nodejs_v22` + `export PATH=/var/apps/nodejs_v22/target/bin:$PATH`）；实测生产先例 `marvis-app` 写的是 `nodejs_v22:OpenVINO-OVMS>=2026.3.0` | 系统**不会**替你注入 PATH（§2.5 实测一致），要自己 export。可声明 `nodejs_v24` 作"帮我装上"的保证。**关键修正**：`/var/apps/{app}/target` 是软链，所以这条路径**与卷号无关、跨机器稳定**——此前"必须猜 vol 号"的顾虑只适用于直连 `/vol{n}/@appcenter/...` |
| 目录映射：`TRIM_APPDEST`→`@appcenter`(应用用户只读)、`TRIM_PKGVAR`→`@appdata`(可写)、`TRIM_PKGETC`→`@appconf`、`TRIM_DATA_SHARE_PATHS`(冒号分隔) | 数据落位依据 |
| **包内 `app/` 的内容 = 安装后 `target/` 的内容**（官方 quick-start 用 `app/www/index.html` → `/var/apps/{app}/target/www` 验证） | 所以 `app/runtime/stub/` → `target/runtime/stub/`，与 `cmd/main` 的 `$TRIM_APPDEST/runtime` 完全对齐；`app/ui/` → `target/ui/`，`desktop_uidir=ui` 才指得对 |
| `resource.data-share.shares[].name` 用 `应用名/子目录`；系统创建目录并自动授予运行用户 **Windows ACL**；`permission`(`rw`/`ro`) **只在要授权别的应用时**才写 | 我们的 `dsh/workspace` 正确，不需要 `permission` |
| 图标：根目录 `ICON.PNG`=64×64、`ICON_256.PNG`=256×256、sRGB、≤1024KB、**主体圆角矩形**；入口用 `images/icon_{0}.png`（**下划线**）→ `icon_64.png`/`icon_256.png` | 核实后发现 M1 两处不符：`ICON.PNG` 生成成了 256×256、入口图标用了 `icon-64.png`。均已在 `make-icons.py` 与 `app/ui/config` 修正，并在 `build.sh` 里加了尺寸/大小断言（尺寸错不会报错，只会静默不显示） |
| 升级钩子：`upgrade_init`（更新前）、`upgrade_callback`（更新后，可做数据/配置迁移）、`wizard/upgrade` | §7 的基础 |
| 已知坑：`settings.conf` 会被系统在**安装/更新/改设置**时重写 | 升级后必须重新落盘 |
| 已知坑：NAS 自动启动时**可能不经过 `cmd/main`** | 配置必须由进程自读 |
| 打包：`fnpack build` → `{appname}.fpk`；有 Windows 版 | 本机可打包 |
| `app/ui/config` 支持 `type: url` / `iframe`；统一网关用 `gatewayPrefix` + `gatewaySocket`，**官方明确支持 WebSocket**，并注入 `X-Trim-Userid`/`X-Trim-Isadmin`/`X-Trim-Username` | **但网关有两个硬条件**：应用必须监听 **Unix Socket**（`${TRIM_APPDEST}/app.sock`），且路由要落在 `gatewayPrefix` 前缀下。dsh 只会监听 TCP `--host:--port`、不支持 base path → 直接接不上，需 socat 桥 + 路径改写。见 §5 |

---

### 2.3 真机实测（第一轮，2026-10-27，主机 `FNOS`）

只读体检，19 OK / 2 WARN / 0 FAIL。下面只列**改变判断**的项：

| 项目 | 实测值 | 对方案的影响 |
|---|---|---|
| 系统 | Debian 12 (bookworm)，内核 `6.18.18.c1126-trim`，x86_64，glibc **2.36** | glibc 门槛（≥2.28）通过；**内核 6.18 比文档写的 6.12 新得多**，Landlock ABI 不会是短板 |
| Landlock | LSM 列表内含 `landlock`（`capability,landlock,lockdown,yama,bpf,apparmor,ima,evm`） | 兜底路径在内核侧成立 |
| bubblewrap | **0.8.0 已装** | bwrap 是**首选**后端，所以它会先被用；0.8.0 偏老，需功能探测确认参数兼容 |
| 系统 Node | `v22.19.0` @ `/usr/local/bin/node`（不满足） | 与预期一致 |
| **`/var/apps` 内有 `nodejs_v24`** | 已安装（`nodejs_v22` 也在） | **推翻"必须自带运行时"的前提**。§3 新增 R1b |
| 内存 / CPU | **11772MB 总 / 7390MB 可用，8 核** | git 源码构建从"4GB 会 OOM"变成"能做，但 8192 堆对 7.4GB 可用仍偏紧" |
| 磁盘 | `/` 40G 可用；`/vol1` **196G** 可用；`/vol2` 96G 可用 | 空间不是约束；`/vol*` 无 `noexec`，可在数据卷跑二进制 |
| 出站网络 | DeepSeek API **401**（= 可达）、npmmirror 200、GitHub 200 | API Key 缺失属正常；网络无障碍 |
| 网卡 | `wlo1` **192.168.0.109**（无线），`0e04c6800b7-ovs` **192.168.0.114**（默认路由源地址），另有 docker0 与两个 br- | **双地址不再是猜测**：我从本机（192.168.0.111）实测两个地址均 ping 通、MAC 不同，都可绑定。但**默认路由源地址 ≠ 一定是客户端用的那个**，仍应做成可配置 |
| 端口 | 3080 / 3081 / 3089 全部空闲 | 无冲突 |
| Docker | 已存在 `docker0` + `br-4318834bfd5d` + `br-2cffcdcd5a8c` | "不用 Docker"是**架构选择**而非环境限制；反过来说明这台机器已有容器负载，需注意端口与内存争用 |
| 打包工具 | `appcenter-cli`、**`fnpack`** 都在 `/usr/local/bin` | 可以在 NAS 上直接 build/install 自签 fpk，M1 回环更快 |

由此修正两条结论：

1. **"必须自带 Node 24"从"唯一选择"变成"仍选它，但理由换了"**。`nodejs_v24` 实测 24.22.1 可用，但只省 13% 体积（§3.1），而代价是启动依赖"某存储卷已挂载 + 该商店应用未被卸载"。所以 v1 仍然自带 —— 不是版本不够，是**不值**。
2. **沙箱风险重心移位**：内核与 bwrap 都在，问题变成"**以应用用户身份（非 root）时 bwrap 还能不能建命名空间**"。这是 fpk 的真实运行身份，也是 root 下测不出来的假阳性来源——已在冒烟脚本里用 `setpriv` 降权复测。
3. 新增一条**开机时序风险**：这台机器唯一的自有 IP 在无线网卡上，而默认路由走 OVS 网桥。若应用在 WiFi/OVS 就绪前启动，`--host 192.168.0.114` 会直接 `EADDRNOTAVAIL` 退出。`cmd/main start` 必须带**地址等待 + 重试**，不能假设网络已就绪。

---

### 2.4 阶段二冒烟结果（2026-10-27 11:22，`@deepseek-ai/dsh@0.2.1-rc.2`）

11 OK / 1 WARN / 0 FAIL。**dsh 在这台机器上跑起来了，公网无关的完整链路成立。**

| 项目 | 实测值 | 含义 |
|---|---|---|
| 运行时 | Node **v24.9.0**（官方二进制）+ npm 11.6.0 | 恰好压在声明的最低线上，**≥24.9 是真的能跑，不是理论值** |
| 安装体积 | **866 MB / 63053 个文件** | **超出我原先 350–600MB 的估计约 40%**，直接改变打包经济性（见 §6.1） |
| profile 合成 | `--profile web` 成功，**299 个插件行** | 插件树能完整装配 |
| 启动耗时 | **3 秒** | `cmd/main status` 轮询和向导"等待就绪"都好设计 |
| 常驻内存 | RSS **406 MB**，11 线程，0 个直接子进程 | 4GB 机型也能跑；单进程模型，收尾简单 |
| 监听 | `192.168.0.114:3089`（确有绑定，`ss` 可见） | 局域网绑定成立 |
| 认证链路 | token → **303** → 跟随后 **200 / 37512 字节** | launch token 换 cookie 的整条路通 |
| 沙箱 | **bwrap 在 root 下通过，`setpriv` 降权到 nobody 仍然通过** | ✅ **关键结论：非特权 userns 可用，fpk 的 `run-as: package` 场景成立** |
| 沙箱兜底 | `landlock-run` 位于 `@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run`，可执行 | 平台分包形式分发，自带运行时路线不会缺 |
| 原生件 | `node-pty` **linux-x64 可加载**，ripgrep 15.0.0 | ABI 匹配 |
| `DSH_HOME` | `storages/`(700)、`storages/workspace.json`(600)、**`.credentials.yaml`(600)**、`profiles/web/`、`.anonymous-user-id`(644) | 直接决定 §4.1 的数据目录映射；`.credentials.yaml` 是 cookie 签名密钥，升级时必须保住 |

**两个必须纠正的认知**

1. **Host 栅栏我上一轮测错了端点**。`admit()` 是"**先查信任、再查认证**"：不信任 → 403，信任但未认证 → 401。但根路径 `/` 走的是先验证 cookie 的索引路由，未认证直接 401，**根本走不到栅栏**。所以"伪造 Host 返回 401"不是漏洞，是我用 `/` 测了一个只挂在 `/api` 上的门。正确断言是：`/api` + 伪造 Host/Origin → **403**，`/api` 无 cookie → **401**。安全模型成立，脚本已改为测 `/api`。
2. **本轮没有真正验证 R1b，但版本问题已排除**。脚本上一版的查找用了 `-type f`，而 fnOS 应用里的 `node` 常是**符号链接**，被过滤掉了；于是它直接落到"复用已下载的官方 node"。应用中心显示 `nodejs_v24` 为 **24.22.1-1**，门槛不是问题。**但按体积重算后不采用它作主路径**（§3.1）：只省约 127MB / 13%，却把启动条件外包给一个可被卸载、且装在某个存储卷上的商店应用。

**由此下调的风险**：沙箱（原"中"→ **"低"**，两档都实测通过）；内存（4GB 机型可用）。**上调的**：体积与文件数（866MB / 6.3 万文件，是 fpk 安装体验的主要负担）。

### 2.5 fnOS 应用目录的真实布局（第二轮实测，2026-10-27 12:24）

**这是本轮最重要的一条认知修正：`/var/apps/<app>` 不是程序目录，而是一层软链骨架。**
`nodejs_v24` 在那里只有 **168KB / 24 个文件**，真正的程序在 `/vol1/@appcenter/nodejs_v24`（**204MB / 4797 文件**）。

| `/var/apps/<app>/` 下的入口 | 指向 | 内容 | 由谁提供 |
|---|---|---|---|
| `target` | `/vol{N}/@appcenter/<app>` | **可执行程序** | fpk 包里的 `app/` |
| `var` | `/vol{N}/@appdata/<app>` | 运行时数据 | 安装时创建 |
| `etc` | `/vol{N}/@appconf/<app>` | 配置 | 安装时创建 |
| `home` | `/vol{N}/@apphome/<app>` | 应用用户家目录 | 安装时创建 |
| `tmp` | `/vol{N}/@apptemp/<app>` | 临时文件 | 安装时创建 |
| `meta` | `/vol{N}/@appmeta/<app>` | 元数据 | 安装时创建 |
| `cmd/` `config/` `i18n/` `manifest` `ICON*.PNG` | 实体 | 生命周期脚本与包元数据 | fpk 包根目录 |

对应到 `TRIM_*` 变量：`TRIM_APPDEST` = `/vol{N}/@appcenter/<app>`，`TRIM_PKGVAR` = `/vol{N}/@appdata/<app>`，`TRIM_APPDEST_VOL` = 该卷根路径（`/vol{N}`）。

**Node 应用本身是一个「库型应用」**，实测证据：

- `manifest` 里 `ctl_stop = false`、`checkport = false`、`disable_authorization_path = true` → **无端口、无 UI、不可启停**，它对外根本不提供服务。
- `bin/node` 是**实体文件**（126.9MB，`-rwxrwxr-x+`，带 ACL），`npm`/`npx`/`corepack` 是软链到 `../lib/node_modules/...`。
- **PATH 里没有它**：`/etc/profile*`、`/etc/environment`、`~/.bashrc` 均无引用。当前 shell 的 `node` 来自 `/usr/local/bin/node`（**v22.19.0**），`/usr/bin/node` 是 **v18.20.4**（dpkg 装的 nodejs）。三套 node 并存，**直接敲 `node` 拿到的是 v22.19，不是 v24**。
- **`npm prefix = /usr/local`**、`npm root -g = /usr/local/lib/node_modules` —— 不是应用目录。所以用它的 npm 做全局安装会写进**系统盘**，并与系统 node 生态共用同一个全局目录。
- 降权 `nobody` 可以执行它（`v24.22.1` 正常输出版本）。

**生产先例：`marvis-app` 已经解决了同一问题。** 它的 manifest 写着：

```ini
install_dep_apps = nodejs_v22:OpenVINO-OVMS>=2026.3.0
```

并在 `cmd/main` 里自己做三件事：探测 node 二进制（`command -v node` 起步）、**从 node 路径反推 bin 目录**、**把该 bin 目录前置注入子进程 PATH**（注释原文：*"MCP 自定义配置用裸命令 npx 时依赖 PATH 解析"*）。

由此得到三条硬结论：

1. **`install_dep_apps` 可以用来依赖 nodejs 应用**（有生产先例），但**系统不会替你注入 PATH**——依赖只保证装上，怎么用是你的事。
2. **复用 node 必须自己探测绝对路径**，但**不要写 `/vol{n}/...`**——官方 `runtime` 页给的写法是 `/var/apps/nodejs_v24/target/bin/node`，`target` 是软链，**与卷号无关、跨机器稳定**。也绝不能依赖裸 `node`：PATH 上是 v22.19，dsh 会直接不满足 `>=24.9`。
3. **不能用它的 `npm -g`**。prefix 在 `/usr/local`，全局装会污染系统盘和系统 node 的全局目录；slim 变体构建必须显式 `--prefix <自己的目录>`。

---

### 2.6 M1 骨架包装机实测（2026-10-27 17:10，第三个真机回合）

`bash build.sh`（skeleton）→ `fnpack` 打包 64KB → `appcenter-cli install-fpk ./dsh.fpk` → `probe/05-verify-fpk.sh`。
结果 **PASS 20 / WARN 2 / FAIL 1**，其中 FAIL 是探针自己的假失败，另外挖出**一个真 bug**。

**装对了的部分（这些之前只是推断，现在是实测）：**

| 项 | 实测 |
|---|---|
| `app/` → `target/` 映射 | 原样落地，`runtime/stub/server.mjs`、`ui/config`、`ui/images/*` 全部在 `/vol1/@appcenter/dsh/` 下 |
| `cmd/*` 执行位 | fnpack 未丢，9 个脚本全 755 |
| 应用用户 | 自动建 `dsh`（uid=971, gid=901 AppUsers, 附加组 dsh） |
| `resource.data-share` | 生效，落在 `$ROOT/shares/workspace`（**复数**），实际路径 `/vol1/@appshare/dsh/workspace`，`TRIM_DATA_SHARE_PATHS` 会传进来 |
| 自动启动 | `install-fpk` 返回后约 5s，应用中心自己调了 `cmd/main start` 成功，`pid==pgid`（setsid 自报 PID 的做法成立） |
| **桌面入口** | ✅ **点图标真的能打开**：应用中心详情页显示 `0.1.1 / 手动安装 / 存储空间1`，带「打开」按钮；点开是 stub 页，显示监听 `192.168.0.114:3080`、Node v24.22.1。§5 里“图标→端口→服务”这条链路从推断变成实测 |

**三个必须记住的坑：**

1. **`fnpack` 会重写 `manifest`**：源文件 649B → 包内/安装后 942B，格式从 `appname="dsh"`
   变成对齐补空格的 `appname                    = dsh`。重写发生在**打包阶段**
   （`tar -xOf dsh.fpk manifest` 里就已经是这个格式，不是安装器干的）。
   所以 `grep -E '^service_port='` 会**静默取空**（探针就是这样假失败的）。
   任何读取 manifest 的代码都要先归一化键，不能假设源文件格式。
2. **目录的遍历位会被改掉**：装完后 `config/`、`wizard/` 的 mode 是 `644`（丢了 `+x`），
   而 `cmd/`、`shares/` 仍 755。root 有 CAP_DAC_OVERRIDE 所以不报错，
   但**以 `dsh` 用户运行的钩子会进不去**——`privilege` 写的就是 `run-as: package`。
   打包前在 `build.sh` 里 `chmod 755` 目录（已加），并在探针里对目录 mode 报警。
3. **`status` 会误报「未运行」（真 bug，已修）**：`is_running()` 拿 `/proc/<pid>/cmdline`
   比对 `$RUNTIME`，但同一目录有两种写法——应用中心调用时 `TRIM_APPDEST=/vol1/@appcenter/dsh`，
   手工调用时回退成 `$SELF_DIR/../target` = `/var/apps/dsh/target`（软链）。
   字符串比对必然对不上 → 进程在跑、端口在听，`status` 却返回 3。
   后果不只是日志难看：应用中心会以为没起来，可能重复 `start` 或拒绝 `stop`。
   修法是比对前把两侧都用 `readlink -f` 展开，四种写法任一命中即认。
   `selftest.sh` 加了对应回归项（用软链复现）。

---

### 2.7 升级机制的第一手实测（2026-10-27 17:25–17:30）——**推翻了 §7 的前提**

结论先说：**`upgrade_init` / `upgrade_callback` 在命令行安装路径上永远不会被调用。**
§7 的整个升级设计建立在“覆盖安装会触发升级钩子”这个假设上，这条假设已证伪。

| 尝试 | 行为 |
|---|---|
| `install-fpk`（包 0.1.1，已装 0.1.0） | `[Info]Application [dsh] is installed.`，**什么都不做**：文件 mtime 不变、无 `upgrade_*` 日志、`appcenter-cli list` 仍显示 0.1.0 |
| `tar -xOf dsh.fpk manifest` | 包内确实是 `version = 0.1.1`（排除“打错包”） |
| `install-local` | 先 `uninstall success` → `installing....` → `[Error]Something wrong with appcenter: code 10237`，**应用被卸载掉了** |

**10237 是 fnOS 平台缺陷，不是包的问题**（社区已定位）：

```
error="10237:fork/exec /tmp/appcenter.pack./cmd/install_init: permission denied"
```

应用中心把临时解包目录 `chown` 给应用用户时**丢了目录的 x 位**（`drw-r--r--`），
随后又以该用户身份执行里面的 `cmd/install_init` → EACCES → 10237。
`install-local` 必踩；官方/社区给的绕法是走**应用中心界面的「手动安装」**上传 fpk。
这同时解释了本包装完后 `config/`、`wizard/` 变成 `644` 的怪现象——同一类“chown 掉 x 位”行为
（我们 `cmd/` 保住了 755，所以 hook 还能跑）。

**对方案的四个硬影响：**

1. **CLI 迭代循环 = `uninstall` + `install-fpk`**，不存在“热覆盖”。`build.sh` 里已加版本守卫，
   版本没变会明确提示“会被静默跳过”。
2. **卸载必须保住用户数据**，否则每次迭代都丢 API Key 与设置。`uninstall_callback` 目前的
   `keep` 只是空转——`@appdata`/`@appconf`/`@apphome` 会被 fnOS 连根删掉（见 §2.8）。
   数据落点已改为 data-share。
3. **升级钩子要靠 UI 验证**：把新版本 fpk 通过应用中心「手动安装」提交，看是否出现“升级”
   以及 `info.log` 里有没有 `upgrade_init`。这是 §7 能否成立的分水岭。
4. **`appcenter-cli uninstall` 不接受手动安装的应用**（`uninstall` 子命令连 `--help` 都只有
   一行 `Usage`，无任何 flag）：一律回 `[Error]Failed to uninstall dsh, please uninstall it
   from Web UI.`。命令行的卸载只有 `install-local` 内部的隐式卸载，而它必踩 10237。
   结论：**卸载只能在应用中心界面点**。

---

### 2.8 数据落点：@app* 会被删光，只有 data-share 活着（2026-10-27 17:30–17:37）

`install-local` 那次内部卸载**真的成功**了，因此留下了一份干净的事后现场：

| 位置 | 卸载后 |
|---|---|
| `/vol1/@appdata/dsh`（`$PKGVAR`：`dsh-home`、`info.log`、pid） | **目录整个消失** |
| `/vol1/@appconf/dsh`（`$PKGETC`：`settings.conf`） | **目录整个消失** |
| `/vol1/@apphome/dsh` | **目录整个消失** |
| `/vol1/@appshare/dsh`（data-share） | **还在**，但被改成 `d---------`（000） |

> ⚠️ 这份现场来自 `install-local` 的**强制**卸载（它绕过了卸载向导）。界面卸载的表现不同，
> 见本节末尾的补充实测——但两者的共同点是：`@appdata` 里的数据都保不住。

也就是说：`uninstall_callback` 里的 `keep` 完全没有意义——目录在它执行之前就没了，
它没有东西可留。要让“卸载重装不丢数据”，数据必须待在 data-share。

**已落地的设计（0.2.0）**：

- `dsh-home`（会话 SQLite、凭据）直接放 `共享目录/.dsh-home`，`chmod 700`；
- `settings.conf` 仍写 `@appconf`（`config` 向导要走这里），但同时在
  `共享目录/.dsh-home/settings.conf` 留一份副本；`install_callback` 读配置时
  **先读 `@appconf`、再读副本**，所以全新安装也能把绑定地址与 API Key 捞回来；
- `install_callback` 安装时自动 `chmod a+rx` 修共享目录的 000（修不了就告警并退回
  `@appdata`，能跑，但升级会丢）；
- `cmd/main` 用同一套推导顺序解析 `dsh-home`，`mkdir` 失败时退回 `@appdata`。
- **副作用（2026-10-28 补记，见 ISSUES F22）**：`HOME` 落进共享目录后，dsh 首启要解析
  「系统文档目录」时，`xdg-user-dir DOCUMENTS` 在缺少 `~/.config/user-dirs.dirs` 的情况下会
  回显 `$HOME`，而 dsh 把「文档目录 == HOME」判为不可用 → 默认工作区建不出来。
  0.6.6 起 `cmd/main` 在启动前写这份文件（`XDG_DOCUMENTS_DIR=<共享目录根>`）并钉住
  `XDG_CONFIG_HOME`，于是两者解耦：**数据**仍在 `.dsh-home`，**默认工作区**落在
  `共享目录/deepseek-harness/default-workspace`（文件管理里可见）。

**补充实测（2026-10-27 18:42，真正的「界面卸载 → 重装」闭环）**——上面那张表要修正：
`install-local` 的隐式卸载**绕过了卸载向导**，属于强制清除，所以它看到的“全删”不能代表界面卸载。

| 位置 | 界面卸载（选「保留会话、凭据与设置」）之后 |
|---|---|
| `/vol1/@appdata/dsh` | 目录还在（770 dsh:dsh），但 **`dsh-home` 已被清空** |
| `/vol1/@appconf/dsh` | **原样保留**（`.probe-keep` 与 `settings.conf` 都在） |
| `/vol1/@apphome/dsh` | 目录还在 |
| `/vol1/@appmeta/dsh` | 目录还在 |
| `/vol1/@appcenter/dsh`、`@apptemp/dsh` | **已删**（安装目录与临时目录，属正常） |
| `/vol1/@appshare/dsh` | 目录还在，被改成 `000`；**`workspace/.probe-keep` 内容存活** |

结论（两条都已被实测钉死）：

1. **`@appdata` 的内容不可依赖**——即便选了「保留」，`dsh-home` 也会被清掉。
   平台文案说的“保留数据目录”，实际保住的是 `@appconf`，不是 `@appdata`。
2. **`@appshare` 里的文件能活过卸载**（只有目录权限被改成 000）。
   重装后 `install_callback` 把 `000` 修回 777 成功，`.dsh-home` 正常创建。

0.2.0 的布局因此在真机闭环里成立：`dsh-home` 与配置副本都在共享目录，
卸载重装后 `install_callback` 重新建出 `.dsh-home`、写入配置并留副本，
`05-verify` 给出 `PASS 23 / WARN 3 / FAIL 0`。

**仍然不要依赖 `@appconf`**：界面卸载保住了它，但 `install-local` 那条路会删掉它，
而 `install-local` 恰恰是命令行上唯一会“卸载”的入口。配置的权威副本留在共享目录。

---

## 3. 核心决策：运行时怎么带进去

| 方案 | 形态 | 体积（实测/推算） | 要改 dsh 仓库 | 风险 | 结论 |
|---|---|---|---|---|---|
| **R1 自带 Node + npm 产物** | `target/runtime/` 里放 node24 官方二进制 + `npm i --omit=dev @deepseek-ai/dsh` 的树 | **866MB（dsh）+ 约 127MB（node）≈ 977MB**（实测；fnpack 压缩后 fpk 199MB） | 否 | 低：等同官方 `npx @deepseek-ai/dsh web` | ✅ **v1 默认** |
| **R1b 复用 fnOS 的 `nodejs_v24`** | 只放 dsh 树，node 用 `/vol{N}/@appcenter/nodejs_v24/bin/node`（实测 **24.22.1**，满足 ≥24.9；**PATH 里没有它**） | 866MB，**只省约 127MB（-13%）** | 否 | **中**：依赖某存储卷已挂载 + 该应用未被卸载/跨大版本替换；且必须自己探测路径 | ⏭ 只作 slim 变体 |
| **R2 单文件 exe** | 用仓库已有 `pkg --sea` 构建，把闭包从 `sdk` 换成 `web` | 单文件约 200MB | 是：新增 web 闭包清单 + 构建脚本 | 中：前端资源 glob、native 插件、仅 Linux 原生构建；**不支持用户装插件**、HMR 关 | ⏭ v2 瘦身 |
| **R3 用 `install_dep_apps=nodejs_v22`** | 依赖系统 Node 22 | 0 | 否 | **致命**：`>=24.9` 不满足 | ❌ 放弃 |

### 3.1 决策：仍然自带 Node，理由从"版本不够"变成了"性价比不够"

`nodejs_v24` 的版本问题已经排除（实测 **24.22.1**，远高于 24.9 门槛），可执行性也排除了（`nobody` 身份正常）。但按实测数字重算，R1b 仍不划算：

| 维度 | 实测/推算 |
|---|---|
| Node 官方 linux-x64 包（tar.xz） | **30.6 MB** 压缩 |
| 解压后 | 官方包约 **120 MB**；飞牛应用实测 node 二进制 **126.9 MB**（整个应用 204MB / 4797 文件） |
| 占 v1 总包（约 977MB）比例 | **约 13%** |
| 换来的耦合 | 依赖 `存储空间1` 已挂载；该商店应用未被卸载/降级/跨大版本替换（`nodejs_v24` → `nodejs_v26` 时路径全变） |

省 13% 的体积，代价是**把"能不能启动"外包给一个用户可以随手卸载的商店应用**。这台机器的 `nodejs_v24` 装在一个**数据卷**上（`/vol1/@appcenter/nodejs_v24`）——该卷在开机时没挂上，`target` 软链就是断的，dsh 直接起不来；fpk 自带的 runtime 不会有这个问题。

另外两条实测结论进一步降低了 R1b 的吸引力（详见 §2.5）：

- **它的 npm `prefix` 在 `/usr/local`**，用它的 npm 全局装包会写系统盘并污染系统 node 生态。要复用只能"借 node 二进制"，构建时还得显式 `--prefix`，省不掉复杂度。
- **PATH 上的 `node` 是 v22.19.0，不是 v24**。复用必须自己定位二进制——用官方推荐的 `/var/apps/nodejs_v24/target/bin/node`（`target` 是软链，不随卷号变化）。`cmd/main` 里多一套路径探测与版本校验。既然这部分代码无论如何都要写，把它写成"探测失败就用自己的"，成本几乎不变。

**结论：v1 走 R1（自带），不做 R1b 主路径。** 但代码上留一个开关：

1. `cmd/main` 的解析顺序固定为 **bundled → system（探测式，不用 PATH）→ 明确报错**（不静默降级）；
2. 构建脚本支持 `--runtime=system` 产出 **slim 变体 fpk**（-127MB），给磁盘紧张的用户；
3. 两种变体共用同一套 `cmd/`、`wizard/`，只在 `app/runtime/` 有无 node 上不同；
4. slim 变体在 manifest 里**同时**声明 `install_dep_apps = nodejs_v24`（有 `marvis-app` 的生产先例，见 §2.5），但**仍然不依赖 PATH**——只把它当作"应用中心会帮我把 node 装上"的保证。

**R1 做法**：下载 Node 24 官方 linux-x64 tar，用其自带 npm 把 dsh 装进暂存目录，整棵树放进 fpk 的 `app/`。
- 用 **npm 的 hoisted 布局**，不用 pnpm（符号链接森林在解包后容易断）。
- 删除 `node_modules/.bin` 里的符号链接，保证零符号链接。
- 原生件核对：`node-pty`、`@vscode/ripgrep`、`@deepseek-ai/node-addon-system` 必须是对应架构的 Linux 产物。
- 体积治理见 §6.1（这是 v1 的主要工作量）。

### 3.2 运行时版本钉定（2026-11-01 复核）

dsh 的 npm dist-tags 与 GitHub 发布**不同步**，不写版本号直接装会拿到旧版：

| 来源 | 版本 | 时间 |
|---|---|---|
| npm `latest` / `next` | `0.2.1-rc.5` | 10-29 |
| npm `alpha` | `0.2.2-alpha.2` | 10-28 |
| GitHub 最新 release | `v0.2.1-rc.5` | 10-30 |
| 官方桌面版 | `0.2.1-rc.3` | — |

**结论：钉 `0.2.1-rc.5`（0.7.1 起）。** 依据：

- 必须显式写版本，不允许 `@latest` 或 `^`：`latest` 长期落后于仓库，最新一次核查时
  `latest` 还停在 rc.2，直接装会拿到旧版。
- rc.4 只存在于 npm 早期快照，**没有对应的 GitHub tag/release**；抽样比对 dsh 主包、
  `dsh-web-app`、`dsh-host-webserver`、`dsh-cmdline`、`dsh-base` 五个包，rc.3 与 rc.4 的
  **文件内容逐字节相同**，只有 `package.json` 里的版本号不同 —— 判定为一次无变更的重发，跳过。
- rc.5 有真实改动：**对话里思考内容的展示优化**（纯前端，用户可见）；依赖集与 rc.3
  **完全一致**（86 个包，仅版本号从 rc.3 → rc.5），没有新增原生件、没有新引擎要求，
  所以「换版本」这件事对 fpk 的体积与架构假设没有影响。
- 再往前的 `0.2.2-alpha.*` 线在改插件体验（富文本详情、第三方插件包更新、热更新失败回滚），
  与我们正在修的 F28/F29 插件链同域，等它转 rc 后再跟。

`build.sh` 里 `DSH_VERSION` 默认值即 `0.2.1-rc.5`，安装后**回读实际版本**校验（npm 的
resolved 版本与请求不一致时直接失败，避免打出一个"看起来是 rc.5 实际是别的"的包）。
未来升级：官方发新 release → 改这一处默认值 → 重打包，不做自动跟随。升级时先核对两件事：
**依赖集有没有新增原生件**、**`cordis.patch.yml` 那套插件接口有没有变**（后者改了我们那份
DDG 搜索插件要跟着改）。

---

## 4. 推荐架构

```
飞牛应用中心
   │  cmd/main start|stop|status（轮询）
   ▼
target/runtime/bin/node  ──  dsh --profile web --host <LAN_IP> --port <PORT> --no-open
   │                            ├─ $DSH_HOME  = var/dsh-home   （会话/凭据/设置）
   │                            ├─ 工作目录   = shares/workspace（用户可见、可备份）
   │                            └─ 监听 <LAN_IP>:<PORT>
   ▼
局域网浏览器 ──► http://<LAN_IP>:<PORT>/?token=<启动令牌> ──► 换 cookie（30 天）
```

### 4.1 目录落位

| 用途 | 脚本里怎么引用 | 实际落位（实测映射，见 §2.5） |
|---|---|---|
| 可执行代码 | `$TRIM_APPDEST/runtime/` | `/vol{N}/@appcenter/dsh/runtime/`（应用用户只读，升级整块替换） |
| `$DSH_HOME` | `$TRIM_DATA_SHARE_PATHS/.dsh-home/`（无共享目录才退回 `$TRIM_PKGVAR/dsh-home/`） | 共享目录下（0660 私有 + 700），**因为 `@appdata` 卸载即删**，见 §2.8 |
| 日志 | `$TRIM_PKGVAR/info.log` | `/vol{N}/@appdata/dsh/info.log`，应用中心标准位置（卸载即失，属正常） |
| PID | `$TRIM_PKGVAR/dsh.pid` | 存 PID 与 PGID |
| 备份/版本状态 | `$TRIM_PKGVAR/backups/`、`$TRIM_PKGVAR/version-state.json` | §7 |
| 工作目录 | `$TRIM_DATA_SHARE_PATHS`（或 `/var/apps/dsh/shares/<name>/`） | 用户安装时选的存储卷 |
| 用户配置 | `$TRIM_PKGETC/settings.conf` + 共享目录里的副本 | `/vol{N}/@appconf/dsh/settings.conf`（卸载即删，所以副本才是权威） |

> **不要硬编码 `/vol1`**：卷号由用户安装时选择，`@appcenter`/`@appdata` 分别落在同一卷的不同 `@` 目录下。所有路径一律从 `TRIM_*` 派生——这是 §2.5 实测出来的硬约束。

### 4.2 进程模型（实战要点）

1. **进程组**：dsh 会 fork 子进程（pty、shell、子 agent）。`start` 用 `setsid` 让 dsh 成为组长，`stop` 用 `kill -TERM -$PGID` 整组退，否则 pty 子进程变孤儿。
2. **status 要便宜**：只 `kill -0` 校验 PID + 一次 TCP 探测端口，不碰 HTTP、不查日志。
3. **绑定 IP 每次启动重算**：`ip route get 1.1.1.1 | awk '{print $7}'`（默认路由源地址）比 `hostname -I | awk '{print $1}'` 更准。
4. **配置自读**：启动时先 `. etc/settings.conf` 拿端口与 IP，覆盖 `TRIM_SERVICE_PORT`。
5. **优雅退出**：SIGTERM 后给 10 秒走 dispose 与持久化排空，再 SIGKILL 整组。
6. **启动前等地址**：`--host` 填的地址若尚未出现在网卡上，进程直接 `EADDRNOTAVAIL` 退出。开机场景必须**先等地址、再起进程**，并带退避重试（实测这台机器默认路由在 OVS 网桥、无线另有地址，见 §2.3）。

> 上述 1/2/6 已实现为可运行原型：`probe/03-run-dsh.sh`（`start|stop|status|url`，`status` 已按 **0=运行 / 3=未运行** 返回）。M1 写 `cmd/main` 时直接搬这套逻辑，不要重写。

### 4.3 端口与配置

- `manifest`：`service_port = 3080`、`checkport = true`。
- 三级优先：`settings.conf` 的 `PORT` > `TRIM_SERVICE_PORT` > `3080`。
- 安装向导收集：API Key、端口、绑定网卡、工作目录。写入 `etc/settings.conf`（在 `install_callback` 里写）。
- API Key 以环境变量 `DEEPSEEK_API_KEY` 注入 dsh 进程；绝不写进 `target/`，绝不回显前端。

---

## 5. 入口方案（点图标能不能直接进）

dsh 每次启动 mint 新 token，而 `app/ui/config` 的 URL 是静态的，塞不进动态 token。三种做法：

| 方案 | 做法 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| E1 手动粘贴 | UI 入口指向裸地址；用户从 `var/dsh-url.txt` 取带 token 的 URL 粘一次 | 零额外组件 | 每次重启都要重取 | 作调试态 |
| **E2 入口跳转器** | 跳转器占 `service_port`（3080），dsh 退到 `<PORT+1>`；跳转器读 `var/launcher.json` 里的本次令牌后 `302` | 点图标即进（0.5.0 起用户零操作） | 多一个进程/端口 | ✅ v1 已实现 |
| E3 fnOS 统一网关 | `gatewaySocket` + `gatewayPrefix`，注入 `X-Trim-Userid` | 复用系统域名与登录态 | 要求应用监听 Unix Socket 且路由留在 `gatewayPrefix` 下；dsh 只能监听 TCP 且只服务 `/` | ⏭ 不做 |

### 5.1 E2 的实现（0.5.0：默认自动带令牌）

dsh 的令牌每次启动重新 mint，且没有「固定令牌 / 关闭鉴权」的开关（web profile 只有
`--host/--port/--tls-cert/--tls-key/--public-url/--trusted-host/--no-open`），
所以「点图标即进」只能靠一层跳转服务。

0.4.0 的做法是设备白名单（首次粘一次令牌，换 180 天 cookie）。真机跑下来用户反馈很直接：
**去命令行取令牌这件事本身就是负担**。于是 0.5.0 换成「跳转器自己取」：

| 环节 | 做法 |
|---|---|
| 令牌来源 | `cmd/main` 启动 dsh 后从**本次新增日志**抓 `token=`，写入 `var/dsh-url.txt` 与 `var/launcher.json`（均 600） |
| 跳转 | 每次请求现读 state，拼 `http://<绑定IP>:<PORT+1>/?token=…` 后 `302` |
| 主机名 | 不照抄 dsh 打印的地址（常是 `127.0.0.1`），用绑定 IP 重建 —— 否则浏览器被送回用户自己的机器 |
| 来源限制 | 仅私有网段自动放行（10/8、172.16/12、192.168/16、100.64/10、fc00::/7、::1）；公网来源仍走配对页 |
| 抓不到令牌 | state 写入 60 秒内给「正在启动」自动刷新页；超过 60 秒给说明页 + 手工配对入口，不把人送到 dsh 的 401 |
| pair 模式 | 完整保留（`launcher-secret` HMAC cookie、180 天、同 IP 5 次失败 429/10 分钟），设置里可切 |
| 跳转目标 | 只 `302`，绝不代理业务流量（代理要改 Host，会破坏 dsh 的 Host/Origin 栅栏） |

两个实现细节值得记住：

1. **cookie 不区分端口**。浏览器 host-only cookie 只按主机名存，所以 dsh 挪到
   `PORT+1` 之后，原先换来的 dsh cookie 仍然有效，用户不会「登两次」。
2. **跳转目标用绑定 IP，不沿用请求里的 Host**。dsh 的栅栏只认绑定 IP；
   若用户通过主机名访问飞牛桌面，跳转器把浏览器送到 IP 上即可。

安全边界的如实记录：`auto` 模式下，**能访问到 `NAS:3080` 的内网设备等于能操作 dsh**
（它带终端与文件工具）。这是用户明确选择的取舍，代价写进了 README 与安装向导：
不要把 3080 映射到公网；要从外网用就走 VPN/Tailscale，或把入口方式改成 `pair`。
公网来源不会被自动放行，这条在代码里，不依赖用户记得。

> 为什么不把 `launcher-secret` 放进共享目录：它在 `@appdata`，卸载会被清，
> 但那只是「已配对设备需要重新粘贴一次」，不影响安全性；放共享目录反而扩大了暴露面。

#### 5.1.1 一个反复踩到的测试陷阱：`sed` 的 `\r` 转义不可移植

`Location` 头是 CRLF 结尾的。曾用 `sed -nE 's/^[Ll]ocation: *(.*[^ ]) *\r?$/\1/p'`
取地址，开发机（GNU sed）通过、fnOS 上必失败：

- GNU sed 认识 `\r` 这个转义，会把它匹配掉；
- fnOS 自带的 sed 不认，把 `\r` 当字面 `r`，于是 `[^ ]` 把行尾的 `\r` 一起捕获进结果。

残留 `\r` 的后果不是「看起来不对」，而是**静默的 000**：
`curl "…?token=x"$'\r'` 报 `URL rejected: Malformed input to a URL function`
并以 exit 3 退出，`-w '%{http_code}'` 只能拿到 `000`；配 `-s` 时连这句报错都被吞掉。
现场表现就是「跳转器给了错地址」，但把同一条地址粘进浏览器又能进——因为浏览器容忍 `\r`。

规则：**取 HTTP 头一律不依赖 sed 的转义**，先 `tr -d '\r'`，再用 bash 裁尾随空白
（`[[:space:]]` 在 bash 的字符类里含 CR，是第二道保险）。`fpk/selftest.sh` 的 `hloc()`、
`probe/05` 与 `probe/07` 的 `getloc()` 都按这条写。

另一条同源教训：调试 curl 不要用 `-s`，用 `-sS`——否则连自己为什么不工作都看不到。

### 5.2 前端闭环：为什么安装/卸载也只能在界面里做

用户的要求是「少一行命令」。当前侧载包的现实是：

- `appcenter-cli install-fpk` 对已装应用只回 `is installed`，没有 force/upgrade；界面上也没有「重新安装」；
- 侧载应用没有更新源，应用中心不会替你检查版本。

所以升级的**唯一**路径是：界面卸载（选保留）→ 界面手动安装新包。为了把这条路上的
命令行全部去掉，`build.sh` 打完包会把 fpk 复制到应用共享目录（`dsh/workspace`），
用户在电脑的文件管理里点一下就拿到，直接拖进「手动安装」。`DSH_STAGE=0` 可关闭。

数据不丢靠的是 §2.8 的落点设计：会话与凭据在共享目录 `.dsh-home`，`settings.conf`
在 `@appconf` 与 `.dsh-home` 双写；重装时向导里 API Key 留空即沿用旧值。

---

## 6. fpk 包结构

实际工程在 `fpk/`（2026-10-27 落地）。✅ = M1 已实现，⏳ = 后续里程碑：

```
dsh/
├── manifest                       ✅ appname=dsh / service_port=3080 / desktop_applaunchname=dsh.main
├── ICON.PNG / ICON_256.PNG        ✅ scripts/make-icons.py 生成（无 Pillow 依赖）
├── config/
│   ├── privilege                  ✅ { run-as: package, username: dsh, groupname: dsh }
│   └── resource                   ✅ data-share: dsh/workspace
├── cmd/                           ✅ 9 个全部实现
│   ├── main                       start / stop / status / restart（0-1-3 契约）
│   ├── install_init               架构 + 磁盘(≥1.5GB) + landlock/bwrap 告警
│   ├── install_callback           dsh-home(700) + settings.conf(600) + chown 应用用户
│   ├── upgrade_init               stop → tar 快照 → runtime 改名为 .old
│   ├── upgrade_callback           校验新 runtime（缺失则恢复 .old）→ 启动
│   ├── uninstall_init/callback    停进程；按向导决定是否删数据
│   └── config_init/callback       停 → 合并配置（留空=不变）→ 重启
├── wizard/
│   ├── install                    ✅ API Key + 绑定地址
│   ├── config                     ✅ 同上，留空表示保持不变
│   ├── uninstall                  ✅ 是否删除数据（默认保留）
│   └── upgrade                    ⏳ M2（展示捆绑的 dsh 版本与破坏性变更）
├── tools/
│   └── dsh-fnosctl                ⏳ M2（version / backup / rollback / doctor）
└── app/
    ├── runtime/
    │   ├── node/bin/node          ⏳ M1b（build.sh full 注入 node24 二进制）
    │   ├── app/node_modules/...   ⏳ M1b（dsh 本体）
    │   └── stub/server.mjs        ✅ M1 占位服务（M1b 后删除）
    ├── portal/                    ⏳ M3（E2 入口跳转器）
    └── ui/
        ├── config                 ✅ .url → key 必须 appname 前缀：dsh.main
        └── images/icon-{64,256}.png ✅
```

包根还额外放了 `build.sh`、`selftest.sh`、`README.md` 三个开发用文件（会被 fnpack 一并打包，对运行无影响）。

`manifest` 关键字段：`source=thirdparty`、`platform=x86`（**每架构一个 fpk**，内嵌 Node 二进制架构绑定）、`ctl_stop=true`、`checkport=true`、`service_port=3080`、`desktop_uidir=ui`、`install_type=`（空=用户可选存储卷）、`changelog`。

> **M1 的两个刻意妥协**：端口固定 3080（`manifest` / `app/ui/config` / `settings.conf` 三处必须一致，否则 `checkport` 与桌面入口会错配）；桌面入口的 host 取"浏览器当前地址"，所以**从哪个 IP 进飞牛桌面，dsh 就得绑哪个 IP**。

### 6.1 体积与文件数（实测后必须处理的问题）

实测：`npm i --omit=dev @deepseek-ai/dsh` = **866 MB / 63053 个文件**。原估 350–600MB，低估了约 40%。

> **现状（2026-10-27，0.6.0）**：瘦身**还没做**——包内 977MB、`dsh.fpk` 199MB，
> 装完 **957M / 63056 个文件**
> （`du -sh /vol1/@appcenter/dsh`，不能用 `/var/apps/dsh`，那里全是软链）。
> 好消息是安装耗时只有约 **22 秒**（`install_init` → `ok`），inode 数没有把安装压垮；
> 所以瘦身的价值从「不然装不上」降级成「省盘、省传输时间」。详见 ISSUES 的 T5。

这不只是磁盘问题，**6.3 万个 inode 才是安装体验的主要成本**——fnpack 打包、fpk 传输、应用中心解包、首次启动扫描，全都按文件数计费。瘦身仍值得做，且**顺序是"先量再砍"**：

| 步骤 | 做法 | 风险 |
|---|---|---|
| 1. 测占比 | 打包脚本先输出 `du -sm` top-20 目录 + 按扩展名统计 | 无 |
| 2. 砍纯装饰 | `**/*.d.ts`、`**/*.js.map`、`**/*.md`、`**/LICENSE*`、`**/.github/**` | 低：运行时不加载；但 `dsh-skill-*` 可能把 md 当资源读，**砍完必须重跑 §2.4 那套冒烟** |
| 3. 砍测试/示例 | `**/test/**`、`**/__tests__/**`、`**/examples/**` | 低-中：同上，必须冒烟验证 |
| 4. 压缩投递 | fpk 内放 `app.tar.zst`，`install_callback` 解包到 `target/runtime` | **待验证**：`install_callback` 是否能写 `TRIM_APPDEST`（清单第 9 项） |

> 不要把 runtime 解到 `@appdata`（可写）图省事：那会让用户数据目录混进 6 万个程序文件，备份/回滚/容量统计全部污染。程序进 `@appcenter`，只有 `$DSH_HOME` 进 `@appdata`。

配套：`manifest` 里 `install_type` 留空让用户选卷，并在 `install_init` 加磁盘门禁
（原按 §6.1 的 1.2GB 设计，**实际落成 1.5GB**，多留了避免解包峰值踩线的余量）。

---

## 7. 更新与升级（专项设计）

> **⚠ 本节的前提已被实测推翻，读之前先看 §2.7。**
>
> CLI 路径（`install-fpk` / `install-local`）**永远不会**触发 `upgrade_init` / `upgrade_callback`：
> 前者对已装应用只回 `is installed`，后者必踩 10237。侧载包目前也没有可靠的「覆盖安装」通道。
> 现行升级流程是**应用中心界面卸载（保留数据）→ 手动安装新包**（ISSUES P1 / P2）。
>
> 本节保留两个用途：① 若 UI 的覆盖安装被验证可行（ISSUES **T11**，待验），这套钩子设计可直接用；
> ② 其中「清 `target/runtime`」「快照」「记录版本态」三件事在**重装路径上同样要做**，
> 只是目前靠人工确认而不是钩子自动执行。
>
> 阅读时请把下文的「覆盖安装」理解为「**如果**平台支持覆盖安装」。

### 7.1 三个必须分开的「版本」

| 版本面 | 载体 | 谁决定 | 升级方式 |
|---|---|---|---|
| **应用外壳** | `manifest` 的 `version` | 我们 | 覆盖安装新 fpk |
| **捆绑的 dsh** | `app/runtime/` 里的 `@deepseek-ai/dsh` 版本 | 上游（迭代很快，官方自称 developer preview） | 随 fpk 一起换 |
| **用户数据格式** | 会话格式代数（当前 **V4**）、SQLite `user_version`（当前 **1**） | 上游代码 | **由程序自动迁移，单向不可逆** |

第三行是整个更新设计的难点：它**不是我们控制的**，而且只前进不后退。

### 7.2 升级契约怎么用

fnOS 对同名同 appname、更高 `version` 的 fpk 执行覆盖安装，触发顺序：

```
upgrade_init（解包前）→ 解包新 app/ 覆盖 target → upgrade_callback（解包后）
```

我们的分工：

- **`upgrade_init`**（解包前，这是唯一能"干净清理"的窗口）
  1. 防御性 `main stop`（不假设系统已停）。
  2. **快照 `$DSH_HOME`**（§7.4），失败就中止升级——写 `$TRIM_TEMP_LOGFILE` 并 `exit 1`。
  3. 检查磁盘空间（≥ 2.5× 当前占用）。
  4. `rm -rf target/runtime`（**关键**：覆盖安装通常只是叠文件，不清旧文件；不清就会出现新旧 dsh 混杂）。
  5. 记录升级前状态到 `var/version-state.json`（会话代数、SQLite user_version、dsh 版本）。
- **`upgrade_callback`**
  1. 重建 `etc/settings.conf`（系统在更新时会重写它）：从升级前读到的值回写端口、IP、Key。
  2. `runtime/bin/node -v` 与 `dsh --version` 冒烟，失败则回滚（§7.6）。
  3. 校验 `$DSH_HOME/.credentials.yaml` 仍在 → **cookie 签名密钥保留，用户不用重新登录**（这是体验细节，但很容易被忽略）。
  4. `main start`，再用 `status` + 一次 `GET /` 确认起来。
- **`wizard/upgrade`**：显示「本次捆绑 dsh X.Y.Z」。判断依据是 `docs/upgrade-guide/<version>/` 是否存在（上游把每个破坏性变更都记在那里）。存在则在向导里显式提示"升级后不可回滚到旧版本"。

### 7.3 升级时序

```
用户装新 fpk
  → upgrade_init
      stop（若在跑）
      backup $DSH_HOME → var/backups/<ts>/
      记录 version-state.json
      rm -rf target/runtime
  → 解包（新 runtime 落到 target/）
  → upgrade_callback
      回写 settings.conf
      冒烟 node/dsh
      start
      verify（status + HTTP 探测）
  → 成功：清理过期备份（保留最近 3 份）
  → 失败：写 $TRIM_TEMP_LOGFILE + exit 1，应用中心显示失败，数据仍在
```

### 7.4 备份策略（升级的保险，不是可选项）

- **备份内容**：`$DSH_HOME` 全量（`sessions/`、`attachments/`、`.credentials.yaml`、settings、SQLite）。**不含** `target/`（可从 fpk 还原）。
- **备份方式**：停进程后 `tar -czf`（别在运行中拷 SQLite，会拿到撕裂的库）。
- **保留**：最近 3 份，按 `var/backups/<timestamp>-<from>-<to>/` 命名。
- **容量**：会话日志会长期增长，附件可能很大。安装向导里给出"当前占用 / 可用空间"提示；磁盘不足时**允许用户选择跳过备份并显式确认**（默认不允许跳过）。
- **可选**：保留上一版 runtime 的压缩包（约 150MB）以便一键回滚，由向导开关控制，默认开。

### 7.5 为什么不做应用内自更新

三条硬理由：

1. **权限**：`target/`（`@appcenter`）对应用用户是**只读**的，进程无法自替换。
2. **可回滚性**：自更新绕过了 fpk 版本记录，出问题无法用"装回旧 fpk"救。
3. **一致性**：`cmd/`、`wizard/`、`manifest` 与 runtime 是同一个版本单元，单独换 runtime 会产生配置与代码错配。

所以：**更新只有一个入口——安装更高版本的 fpk**。应用内最多做"有新版本"的提示（§7.8）。

### 7.6 回滚：能力与边界（要写进用户文档）

**能做的**：恢复代码（装回旧 fpk）+ 恢复数据（还原备份目录）。`tools/dsh-fnosctl rollback [备份目录]` 做这件事。

**做不到的**（必须诚实告知）：

> 一旦新版本把会话写成更高的格式代数，或把 SQLite `user_version` 提升，**旧版本会拒绝打开它们**——会话是 `refuses a future version`，数据库是 `incompatible with this build`。这不是配置问题，改不回来。

因此：

- 回滚 = **代码回退 + 数据回到快照点**，新版本运行期间产生的会话会随之丢弃。
- 若用户想保住那批新会话，只能**前进**（装更新的 dsh），或手工把 `var/dsh-home/sessions/` 里新代数的目录移出去留档。
- `doctor` 命令应打印：当前会话最大代数、SQLite `user_version`、以及"能否安全降级到 X 版本"的判断。

### 7.7 `dsh-fnosctl`（一个脚本，四个动词）

| 命令 | 行为 |
|---|---|
| `version` | 打印应用版本、捆绑 dsh 版本、会话代数、SQLite user_version |
| `backup [--tag]` | 停机快照 `$DSH_HOME`，输出路径与体积 |
| `rollback [dir]` | 校验目标备份 → 装回对应 fpk（提示路径）→ 还原数据 → 启动 |
| `doctor` | 只读诊断：磁盘、备份完整性、沙箱后端、端口占用、版本兼容性 |

### 7.8 版本检查与提示（可选，不自动下载）

- 检查源：npm registry 的 `@deepseek-ai/dsh` 最新版 + 我们自己的 fpk 清单。
- 频率：**每 24 小时一次**，超时/失败静默，写 `var/update-check.json`。
- 展示：入口跳转页（E2）顶部一行"有新版本可用"，以及设置页。**不出现"一键更新"按钮**（原因见 §7.5）。
- 上架应用中心后，这一层可降级为纯提示，更新交给系统。

### 7.9 版本号约定

- `manifest.version` 用我们自己的语义化版本（如 `1.0.0`、`1.1.0`），**不要**直接抄 dsh 版本。
- 捆绑的 dsh 版本写进 `desc` / `changelog` / `var/version-state.json`，例如 `changelog = 升级捆绑 dsh 至 0.2.2（含会话格式 V5 迁移，升级后不可降级）`。
- 这样应用的破坏性变更与上游的破坏性变更**两套版本线互不打架**，排查问题也说得清。

### 7.10 升级前的 preflight 门禁

任一不满足则**中止升级并保留旧版本**：

1. 磁盘剩余 ≥ 2.5 × `$DSH_HOME` + 新 runtime 体积。
2. 备份成功且可列出内容（不是空包）。
3. 目标 fpk 的 runtime 与本机架构匹配（`uname -m`）。
4. 当前无其它实例占用端口。
5. 若新版本会 bump 会话代数 → 向导里必须有用户确认。

---

## 8. 安全模型（必须写进安装向导和文档）

**核心事实：打印出来的 token URL 就是密码，等价于以应用用户身份执行任意命令。**

1. `run-as: package`，**绝不用 root 模式**。爆炸半径 = 应用目录 + 授权的共享目录。
2. 只绑具体局域网 IP（架构强制）。
3. token 文件 `chmod 600`，放 `var/` 不放 `shares/`。
4. 不接入 FN Connect / 不做公网端口映射。
5. 明确告知：局域网内任何拿到 URL 的人 = 完整控制权；被授予该目录的其它飞牛用户也能读到 `var/`。
6. 可选加固：`--tls-cert/--tls-key` 自签证书（cookie 变 `Secure`，浏览器有告警）；或 E2 之后加一层 basic auth（**前提：TLS 或可信内网**）。
7. 保留 dsh 的人工确认策略（`workspace-write` 起步），不要一上来给 `danger-full-access`。
8. **用户授权目录 = 由用户按需扩大爆炸半径**（`manifest.disable_authorization_path=false`）。
   应用默认只能碰 `data-share` 那块；用户在「应用设置 → 访问权限」里加的每个文件夹，
   平台会把 ACL 授给 `dsh`，之后 dsh 的目录选择器（远程访问下走 browse 后端，能列全盘）
   就能把该目录当工作区，agent 在里面读写与执行。这比「一开始就 root / 全盘可读」好得多：
   权限粒度是**用户逐个目录点出来的**，且可随时收回（删掉授权项）。
   代价是必须说清：**授权读写 = 把该目录交给 agent 全权处置**，向导与文档都要写明。
   （0.6.6 及以前这里写的是 `true`，等于把这条路堵死，见 ISSUES F23。）
9. **授权目录的「可见性」由我们在启动时补**（0.6.8，`link_accessible_paths()`）。dsh 的目录选择器
   从 `homedir()` 起步，而本封装的家目录是 `.dsh-home`（隐藏的应用数据目录），前端又把家目录
   以上折成「主目录」一个面包屑 —— 结果是有权限也点不过去（ISSUES F24）。做法是把每个授权目录
   软链进 `$HOME/可访问目录/`：**软链只当入口，登记进工作区的是 `realpath` 之后的真实路径**，
   所以既不影响 dsh 的路径去重判据，也不额外扩大权限面（能进还是靠平台给的 ACL）。
   注意跳过「包含 `$DSH_HOME` 的授权路径」，否则会递归成无限层级。

---

## 9. 里程碑

| 阶段 | 内容 | 出口判定 |
|---|---|---|
| **M0 可行性验证**（NAS 手工，不打包） | 下 Node24 tar → `npm i @deepseek-ai/dsh` → `dsh --profile web --host <IP> --no-open` | 另台设备浏览器能进 UI 并跑完一个回合；沙箱不是 `SANDBOX_UNAVAILABLE` |
| ↑ **M0 现状（2026-10-27）** | 服务侧全部通过（§2.4） | **剩下两件**：① 从另一台设备的**浏览器**真进去（目前只用了 curl）；② **跑完一个回合**——需要先配 `DEEPSEEK_API_KEY` |
| **M1 最小可用 fpk** | ✅ **骨架已写完**（`fpk/`，2026-10-27）：9 个生命周期脚本、3 个向导、桌面入口、`selftest.sh`、`build.sh` | `install-fpk` 装上 → 可启停 → 重启 NAS 后自动拉起 |
| ↑ **M1 现状（2026-10-27 21:09）** | **完整包 0.5.0 已装机验收**：`probe/05` 33 PASS / 1 WARN / 0 FAIL、`probe/07` 10 PASS；数据在共享目录且跨卸载存活 | 出口判定三条：装上 ✅、可启停 ⚠️（应用卡片没有「停止」，根因 F17 已修待装包）、**重启 NAS 后自动拉起未验**（§10 第 22 项） |
| **M2 更新闭环** | 原设计 `upgrade_init/callback` + 备份 + `dsh-fnosctl` + preflight | ~~装 v1.0.0 → 覆盖装 v1.1.0~~ **被平台卡住**：CLI 无覆盖安装（P1）、`install-local` 踩 10237（P3） |
| ↑ **M2 现状** | 现行闭环 = **卸载（保留）→ 手动安装**，已随 0.5.0 实跑通过；`upgrade_*` 钩子代码仍在但走不到 | 待验：UI 覆盖安装能否替代卸载（**T11**）。在那之前，`dsh-fnosctl` / preflight 不做 |
| **M3 体验补齐** | E2 入口跳转器 ✅ **0.5.0 已实现**（点图标即进）、配置变更重启 ✅、版本提示未做 | 点图标直接进 UI ✅；升级向导「是否含破坏性变更」未做（无覆盖安装，先搁置） |
| **M4 可选** | 自签 TLS、R2 单文件瘦身、E3 网关接入、商店上架 | 按需 |

---

## 10. 待实测清单（必须在真机确认，不能靠文档推断）

**状态（2026-10-27 23:55）**：原 26 项中 **13 项已有结论**（其中第 9 项的结论是「证伪」），
**还剩 13 项**未验，按「会不会挡下一步」分成三组。已确认项只在 §10.4 留结论，不再列为待办。

### 10.1 会挡下一步的（4 项）

| # | 待测 | 为什么挡 | 判据 |
|---|---|---|---|
| 8 / 10 | UI 手动安装更高版本是否覆盖升级；`upgrade_init` 执行时应用是否已被停 | 决定以后每次升级要不要先卸载，也决定 §7 那套钩子还有没有用 | 见 ISSUES **T11**（含逐步命令） |
| 7 | 应用中心是否默认开机自启 | 决定 T8 看护要不要做、怎么做 | 重启 NAS 后进程是否自己回来 |
| 22 | 重启 NAS 后是否自动拉起 | 同上：官方没有 systemd 集成，全靠应用中心调度 | 重启后 `ps` + `curl loop` |
| 15 | 开机时序：网络未就绪时 `--host` 会不会 `EADDRNOTAVAIL` | 与 22 是同一场景的两面，绑错地址会直接退出 | 重启后看 `info.log` 有无地址绑定失败 |

### 10.2 只影响特定场景（5 项）

| # | 待测 | 何时才会咬人 |
|---|---|---|
| 3 | `node-pty` 能否实际 open 一次 pty | 在 UI 里真跑一条终端命令（目前只验到原生件可加载） |
| 16 | OVS 桥地址 `.114` 是否稳定 | 重启 / DHCP 续约 / 无线重连后地址变了 → 入口打不开（T6） |
| 17 | `run-as: package` 下的真实沙箱档位（bwrap / Landlock / 不可用） | 用户遇到 `SANDBOX_UNAVAILABLE` 时才需要区分 |
| 11 | 系统重写 `settings.conf` 的时机（安装 / 更新 / 改设置三处） | 改设置后配置丢失 |
| 24 | `app/ui/config` 的 port 与实监听不一致时的行为 | 做 T3（端口可配）那天 |

### 10.3 与瘦身 / 排障相关（3 项，不挡路）

| # | 待测 | 备注 |
|---|---|---|
| 14 | `install_dep_apps = nodejs_v24` 是否被应用中心接受 | 瘦身方案的前置；已有 `marvis-app` 用 `nodejs_v22` 的先例 |
| 18 | `nodejs_v24` 被升级或卸载时 fpk 的行为 | 只有走 slim 变体才相关 |
| 20 | `/usr/local/bin/node`（v22、121MB、非 dpkg 管理）的来历 | 只影响排障：用户敲 `node -v` 会看到 v22，以为装错了 |

### 10.4 已确认（结论留档，不必再测）

| # | 结论 |
|---|---|
| 1 | Landlock 已启用（lsm 列表含 landlock） |
| 2 | bwrap 在 root 与 `nobody` 下均通过，非特权 userns 可用 |
| 4 | 3080 / 3081 / 3089 空闲 |
| 5 | 应用用户出站 HTTPS 可达（DeepSeek 401、npmmirror / GitHub 200） |
| 6 | 首次冷启动 RSS 406MB / 11 线程 / 3 秒 → 4GB 机型可用 |
| 9 | 自签 fpk **不会**触发 `upgrade_init/callback`：只回 `is installed`，文件 mtime 不变 |
| 12 | 大 fpk：包内 977MB / `dsh.fpk` 199MB / 装完 957M、63056 文件，`install_init → ok` 约 **22 秒** |
| 13 | 统一网关支持 WebSocket；瓶颈在 dsh 侧（要 Unix Socket + 前缀），v1 不做 |
| 19 | `cmd/main` 的 PATH 里确实有 v22 干扰，但启动一律用 bundled node 绝对路径，未受影响 |
| 21 | fnpack 保留 `cmd/*` 执行位：装机后 9 个全 755 |
| 23 | `run-as: package` 身份 = `dsh` uid 971；`settings.conf` 600、`dsh-home` 700 |
| 25 | 向导 `initValue` 不接受布尔值，必须字符串（否则 `fnpack build` 失败） |
| 26 | fnpack 校验只报文件名、不报字段 → 本地必须字段级自查（`build.sh` 已做） |

---

## 11. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| token URL 泄露 = 远程任意命令执行 | 高 | §8；默认不暴露公网；文档显著提示 |
| **升级后无法降级**（会话代数 / SQLite schema 单向） | 高 | 强制快照 + 向导显式告知 + `doctor` 打印可降级性；回滚定义为"回到快照点" |
| 覆盖安装残留旧文件导致运行时错配 | 中 | `upgrade_init` 清 `target/runtime`；`doctor` 校验版本一致性 |
| 沙箱不可用 | **低**（已实测） | bwrap 在 root 与非 root 下均通过；仍有 Landlock 兜底。装后 `doctor` 打印实际档位 |
| fpk 体积大、文件多，安装慢/失败 | **高**（实测 866MB / 6.3 万文件） | §6.1 瘦身 + `tar.zst` 投递；`install_init` 加磁盘门禁 |
| dsh 迭代快、破坏性变更频繁 | 中 | 固定版本打包；升级前查 `docs/upgrade-guide/<version>/` |
| 网关接入需 Unix Socket + 前缀改写，成本被低估 | 低（已排除出 v1） | 明确推迟；v1 走端口 + 跳转器。官方已确认支持 WS，缺的是 dsh 侧适配 |
| 多网卡/多 IP 选错绑定地址 | **中**（实测双地址） | 启动时探测 + 向导可改；须从客户端实测而不是看默认路由 |
| **开机时序**：网络未就绪时绑定地址不存在，进程直接 `EADDRNOTAVAIL` 退出 | 中 | `cmd/main start` 做地址等待 + 退避重试（§2.3 第 3 条） |
| 用户误以为多用户隔离 | 中 | 文档与向导明确"单身份、共享权限" |

---

## 12. 需要你确认的取舍

> 方案早期的开放问题。**现在只剩第 6 条还开着**，其余已由实现或实测定下来。

1. ~~**运行时**：R1b 还是 R1~~ → **已定：R1 自带**（§3.1）。系统的 `nodejs_v24` 是 24.22.1、`nobody` 可执行，但只省 13% 体积；不拿"能否启动"去换这 13%。slim 变体作为可选构建保留。
2. ~~**入口**：先接受"首次手动粘一次 token"，还是一开始就做跳转器？~~ → **已定：做了跳转器**。0.5.0 起点图标即进（§5.1），令牌由跳转器自己从启动日志取。
3. ~~**是否要 TLS**~~ → **暂不做**。入口只在局域网，自签证书的浏览器告警比收益大；接 T7 网关后由网关终结 TLS 更合适。
4. ~~**升级时是否默认保留上一版 runtime**~~ → **问题消失**。侧载包没有覆盖安装（§2.7 / ISSUES P1），每次都是卸载后整包替换，旧 runtime 随卸载一起没。
5. ~~**备份不可跳过还是允许跳过**~~ → **暂不做**。升级不走 `upgrade_*` 钩子，快照目前只能手动；等 T11 验证覆盖安装后再定。
6. **绑定地址（仍待你决定）**：当前实现是「启动时探测默认路由源地址」（`DSH_BIND=auto`），
   向导里**没有**下拉框。双地址环境（`.109` 无线 / `.114` OVS）下这就是 T6 的来源。
   两个选项：① 向导加一个「绑定地址」下拉（更稳，多一步）；② 等 T7 统一网关，
   把 launcher 收到 `127.0.0.1`，这个问题整个消失。**我倾向②**，但前提是你认可做 T7。

---

# 附录 A：不用 fpk，直接 git 部署（可行性评估）

结论先说：**技术上可行，能最快跑起来，但你得到的是「自建服务」而不是「应用中心应用」**。真正的成本不在 `git pull`，而在**把构建工具链搬到 NAS 上**。

## A.1 先分清三种「不装 fpk」的路径

| 路径 | 拿到的代码 | NAS 上要不要构建 | 更新方式 | 适用 |
|---|---|---|---|---|
| **N1 npm 安装**（其实不需要 git） | `@deepseek-ai/dsh` 发布包 | **不要** | `npm i @deepseek-ai/dsh@<ver>` | ✅ 只想跑起来 |
| **G1 git 源码** | 完整 363 包 monorepo | **要**（`pnpm install` + `build:artifacts`） | `git checkout <tag>` + 重建 | 要改源码 / 要做 fpk |
| **F1 fpk**（本方案主线） | 打包好的 runtime | 不要 | 覆盖安装 fpk | 要应用中心集成 |

如果你的诉求只是"不想每次装 fpk 才能更新"，**N1 才是答案，git 不是**。git 方案唯一独占的价值是：**你能修改 dsh 的代码**。

## A.2 git 源码路径的硬门槛

| 门槛 | 实测/推算 | 说明 |
|---|---|---|
| Node ≥ 24.9 | 本机已装 `nodejs_v24` **24.22.1** | §3 R1b；但 PATH 上是 v22.19，**必须用绝对路径** |
| pnpm 11.28.5 | `packageManager` 字段锁定 | 用 corepack 或独立安装（本机已有 pnpm 12.5.1，**版本高于锁定值**，需 `corepack` 或 `--force`） |
| **构建内存** | **实测 11772MB 总 / 7390MB 可用，8 核 → 可做** | `build:lib:host` 硬编码 `--max-old-space-size=8192`，对 7.4GB 可用额度仍偏紧，建议先停掉其他容器/应用 |
| 磁盘 | 源码 0.5GB（`.git` 331MB + 工作区 170MB）+ `node_modules` 估 2–3GB + 构建产物 | 合计 **3–4GB**，需实测 |
| 网络 | `pnpm install` 拉数千个包 | 国内需配 registry 镜像；首次安装耗时不可忽略 |
| 构建时间 | 弱 CPU 上 **10–30 分钟**（含 tsc 全量 + tsdown + Web 打包） | 期间服务不可用，除非做 A/B（见 A.4） |
| 原生依赖 | `node-pty`、`@vscode/ripgrep`、`node-addon-system`、`esbuild` | 需对应架构的 Linux 预编译件；`allowBuilds` 白名单已放行 |
| Web UI | **必须先 `pnpm run build:artifacts`** | `pnpm dsh web` 本身用 tsx 直跑 TS，但静态资源要靠构建产出 |

## A.3 进程怎么守护（fpk 帮你的部分，这里得自己做）

没有 fpk = 没有应用中心的 `cmd/main`、没有图标、没有启停按钮、没有端口登记。NAS 是 Debian + 有 root，所以：

- 写一个 **systemd unit**（`User=dsh` 专用用户、`Restart=on-failure`、`WorkingDirectory`、`EnvironmentFile`），比 fpk 的脚本模型更省心。
- 开机自启交给 systemd。
- 但注意两个"系统更新可能清掉"的位置：`/etc/systemd/system/` 与 `/opt/`。**代码目录建议放数据卷**（`/vol1/...`），并保留一个 `install.sh` 以便系统升级后一键重装 unit。

## A.4 生产化的 git 部署：A/B 目录 + 原子切换

直接 `git pull && pnpm build && systemctl restart` 有个致命缺陷：**构建失败的瞬间服务已经停了，且旧版本已被覆盖**。正确做法：

```
/vol1/dsh/
├── releases/
│   ├── v0.2.1-rc.5/     ← 正在服务
│   └── v0.2.2-rc.1/     ← 新构建完成待切换
├── current -> releases/v0.2.1-rc.5   （符号链接）
└── shared/              ← $DSH_HOME、logs、settings
```

流程：`git worktree`/`git clone` 到新 release 目录 → 构建 → 冒烟（`--dump-config`）→ `ln -sfn` 原子切换 → `systemctl restart` → 验证。
- **回滚** = 把符号链接切回去 + restart，秒级，不用重新构建。
- 构建期间旧版本照常服务。
- 代价：磁盘翻倍（每个 release 3–4GB）。

## A.5 git 方案特有的风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| **master 是移动靶** | dsh 自称 developer preview，"THERE WILL BE COMPATIBILITY-BREAKING CHANGES"；`git pull` 拉到的是未发布状态，可能编不过、可能改协议 | **只 checkout 发布 tag**（`dsh-v0.2.1-rc.3` 这类），永不跟 master |
| **构建失败即事故** | 没有 A/B 就是服务中断 | A.4 的 releases 目录 |
| **更新成本高** | 每次更新 = 全量重建，10–30 分钟；fpk 方案是解包即完 | 接受，或用 N1 |
| **系统升级可能清掉 unit** | `/etc` 与 `/opt` 不一定保留 | 代码放数据卷 + 重装脚本 |
| **会话格式仍不可降级** | §7.6 的边界一条不少 | 同样要备份 + `doctor` |
| **无应用中心可见性** | 用户不知道它装了、占多少空间、是否在跑 | 自建一个 `status` 脚本或主页 |

## A.6 建议的落地顺序

1. **先 N1**：NAS 上装 Node 24 + `npm i @deepseek-ai/dsh`，`dsh web --host <IP> --no-open` 跑通——这一步和 fpk 方案的 M0 完全重合，**先验证环境与沙箱**，成本最低。
2. 跑通后判断你的真实需求：
   - 只是想用 → **停在 N1**（+ systemd unit），别上 git，别做 fpk。
   - 想改源码 / 要双版本切换 → 上 **G1 + A.4 的 A/B 目录**。
   - 想给别人装、要应用中心图标和启停 → 回到 fpk 主线。
3. 三者可以共存：fpk 装的是 runtime，git 目录装的是源码，共用同一个 `$DSH_HOME` 会打架——**一个 NAS 上只跑一种**。

