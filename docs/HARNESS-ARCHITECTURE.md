# DeepSeek Harness 实现原理（以及它对 fnOS 适配意味着什么）

状态：**分析稿 v1.1（2026-11-02）**　底本：`/e/Project2/deepseek-harness` master HEAD `ce7073d`
（`0.2.2-alpha.2`，2026-10-30）；初版基于 `0.2.1-rc.3`，两者差异见 §11。
本包实际钉的 npm 版本仍是 `0.2.1-rc.5`（理由见 §11.3）。

> 这份文档回答两个问题：**dsh 是怎么长成这样的**，以及**它的哪些设计直接决定了
> fpk 封装只能这么做、不能那么做**。第二列比第一列更重要——适配层每一条"看着奇怪"
> 的代码，几乎都能在这里找到上游的硬约束。

---

## 0. 一句话

dsh 不是一个"有插件系统的应用"，而是**一棵运行时组装出来的 Cordis 插件树**：
模型适配器、工具注册表、会话日志、沙箱、甚至 agent loop 本身都是插件。
`dsh --profile web` 做的事，是把若干组合包（bundle）按顺序叠在一张空配置上，
再用 patch 覆盖出"Web 产品"这一具体形态。

这个设计带来两个后果，贯穿全文：

1. **没有固定入口 API**：HTTP 服务器、认证、路由都由插件贡献，所以"给 dsh 套一层"
   只能在**进程外**做（端口、代理），不能指望改一行配置就换监听方式。
2. **一切注册都是可撤销的副作用**：插件卸载即撤销，这让运行时状态（profile、store、
   已装插件）成为外部可观察、也可被外部破坏的东西——fnOS 上的 F30（pnpm store 错配）
   就是这一类。

---

## 1. 运行形态：profile / bundle / patch 三层叠加

```
dsh --profile web
  └─ profile（$DSH_HOME/profiles/web）        具名组装：列出要叠的 bundle、装自己的树外插件
       ├─ bundle: dsh-base                    模型适配器、工具、持久化、沙箱、设置、凭据、遥测
       ├─ bundle: dsh-web-app                 浏览器应用（HTTP 载体 + 前端资源）
       ├─ cordis.patch.yml（profile 自己的）   按 id 替换某条目的整个 config，或插入新条目
       ├─ home patch（$DSH_HOME 下）
       └─ --patch overlay（命令行最高优先）
```

- **bundle** 是分发格式：`package.json` 的 `dsh.bundle` 指向一个 patch 文件。
- **profile** 是 `package.json` 的 `dsh.profile` 列出 bundle 清单，并拥有自己的
  `cordis.patch.yml`（用户改这里，不改别人的包）。
- 叠加顺序即优先级：profile 里的 bundle 顺序 → profile patch → home patch → `--patch`。
- `dsh --profile web --dump-config` 打印最终配置树。**这是排障时唯一可信的"实际形态"**，
  比读文档可靠。

**对适配的含义**

| 事实 | 封装层的约束 |
|---|---|
| profile 落在 `$DSH_HOME/profiles/<name>`，含 `node_modules` | 升级换 runtime 时**不能删 profile**，否则用户装的插件全没（我们的做法：只清 `target/runtime`） |
| 插件装进 profile 的 `node_modules`，由 pnpm 管理 | 必须自带 pnpm + npm（F28/F29）；store 位置必须与已有 `node_modules` 对齐（F30） |
| 监听地址/端口默认来自 `--host/--port`（`web-app/cordis.patch.yml:179` 的 `host: !!js ctx.webStartup.host ?? '127.0.0.1'`），但那是**普通配置值** | 后叠加的 patch 层（profile / `--patch`）**能**把它改成 `0.0.0.0`，绕过 CLI 校验（见 §5.1 的更正）。我们不做，原因在 §5.4 |

---

## 2. 轮次流程：turn / step 与四个事件域

一个**步骤**＝一次模型请求 + 它调用的工具；一个**轮次**＝零或多个步骤，
"在领取首条输入前打开，在不再欠工作时关闭"。

```text
turn/start
  claim 输入 → 快照模型选择 → 组装 prompt sections + 本步准入的工具 schema
  → agent/pre-step（waterfall：可拒绝/改写/接纳）
     step/start
     agent/request → prepareCall() 绑定适配器
     提交 system/message + user/message，冻结模型历史
     llm/stream → agent/assistant-stream（start / chunk* / end）
     tool/call* → tools/pre-execute → tools/execute → tools/post-execute → tool/result*
     step/end
     还欠请求或有新输入 → 下一步
  → agent/turn-stopping（serial）→ turn/end
```

事件分三个域，用途严格区分：

| 域 | 是否持久 | 用途 |
|---|---|---|
| **会话事件**（`turn/*`、`step/*`、`user/message`、`assistant/message`、`tool/*`） | 是，追加进日志 | "重载后仍然成立的事实" |
| **Agent 事件**（`agent/*`） | 否，进程内 | 观察/拦截进行中的工作（inbox、步骤、取消、续跑） |
| **能力事件**（`fs/*`、`tools/*`、`telemetry/*`） | 否 | 给某个 seam 挂策略或适配器 |

**对适配的含义**：会话日志是**唯一**的模型上下文来源（`deriveMessages()` 从中投影）。
所以 `$DSH_HOME` 一旦丢，丢的不是"聊天记录"，是**智能体的记忆本身**——这解释了
为什么卸载会清 `@appdata` 这件事在我们这里被当成 P0 级平台限制（P6/F35），
也解释了为什么升级前必须快照。

---

## 3. 能力 seam：一个接口，三种角色

seam ＝ 可替换能力，由 **Service Definition**（声明接口）、**Provider**（实现）、
**Consumer**（通常是面向模型的工具）三方构成。文件系统与进程提供方共享同一个
"执行世界"，所以把它们指向远程沙箱，Bash、PTY、LSP 会一起搬过去。

主要 seam（与封装相关的）：

| seam | 提供方 | 对封装的意义 |
|---|---|---|
| `ctx.fs` | 本地 / 沙箱 | 决定 agent 能读写哪里；我们靠 `data-share` + 用户授权目录喂它 |
| `ctx.shell` / `ctx.terminals` | 本地 subprocess / pty | 会 fork 子进程 → **stop 必须整组回收**（`setsid` + `kill -PGID`） |
| `ctx.sandbox` | bwrap → landlock（Linux 链） | 见 §4 |
| `ctx.llm` | DeepSeek 适配器 | API Key 走 `DEEPSEEK_API_KEY` 环境变量 |
| `ctx.subagent` | 新建子 agent / 委派别的产品 | 会产生子进程与额外 token 消耗 |
| `ctx.credentials` | 本地 `$DSH_HOME/.credentials.yaml` | cookie 签名密钥在这里，升级必须保住 |

---

## 4. 沙箱：按平台选链，按功能探测选档

`packages/sandbox/sandbox-local`：

- 平台链**先按平台定**，链上多于一个候选时才探测仲裁：
  `linux: ['bwrap', 'landlock']`、`darwin: ['seatbelt']`、`win32: ['windows-acl']`。
- bwrap 的 profile 是固定骨架：
  `--ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent`，
  `workspace-write` 时再 `--tmpfs /tmp` + 对可写根 `--bind`。
- 探测是**功能性**的（真起一个进程），不是 `command -v`。bwrap 存在但探测失败会
  **静默降级**到 Landlock——两者的权限语义不同，所以 PLAN 里坚持"两档都实测"。

**对适配的含义**：fpk 的 `run-as: package` 是非 root 身份，而 bwrap 需要非特权
user namespace。真机已实测通过（root 与 `nobody` 都过），这是"不用 Docker 也能有
文件/进程隔离"的前提。若某台机器 userns 被禁，会降级到 Landlock 而不是不可用，
**不要把它当成启动失败**——日志里应打印实际档位（`doctor` 的职责）。

---

## 5. Web 载体：一个 `node:http` 服务器 + 两道栅栏

### 5.1 服务器本身很薄

`dsh-host-webserver` 只做四件事：监听、具名路由表（exact / prefix）、可选 gzip、
以及一个**唯一的 fallback 席位**（发布的 Web 组合由 `frontend-static` 认领，
即 SPA dist 服务器）。业务路由（`/api`、插件 bundle、HMR）都由别的插件注册。

`Config.host` 的注释写死了三件事，直接决定我们的入口方案：

1. 必须是**本机某个具体接口的 IPv4/IPv6 字面量**；
2. **未指定地址（`0.0.0.0`/`::`/其映射形式）在 CLI 解析阶段被拒绝**——理由是
   "会一次性把端口暴露在所有接口上"；
3. 回环字面量只服务本机，其它字面量服务该地址所属网络。

> **2026-11-02 更正（对着社区实现复核时发现）**：这道闸门**只装在 CLI 上**。
> `isWildcardHost()` 的唯一调用点是 `packages/bundle/web-app/src/startup.ts:95`，
> 它拦的是 `--host` 的取值；而真正传给 `server.listen()` 的是
> `packages/host/webserver/src/index.ts:621` 的 `this.config.host`，该字段没有二次校验。
> 于是后叠加的 patch 层写 `webserver.config.host: 0.0.0.0` **确实能绑通配**——
> 社区项目 `techysy/deepseek-harness-fnos` 就是这么做的（它明确写"绕过 CLI 0.0.0.0 校验"）。
> 结论：这是"上游不希望、但结构上挡不住"的旁路，不是"做不到"。我们仍选择不用，理由见 §5.4。

### 5.2 认证：launch token → cookie

- 每个进程 mint 一枚随机 launch token；
- 只在 `GET /`（和 API 的 `/connect`）接受 query token，换一枚
  **authority 绑定**的签名 cookie：`HttpOnly`、`SameSite=Strict`、`Path=/`、默认 30 天；
- cookie 的 audience ＝ **规范化 hostname + port**（TLS 时还带 scheme）；
- 签名密钥是 `ctx.credentials` 里 `client-connection/browser-session` 这条记录，
  本地提供方落在 `$DSH_HOME/.credentials.yaml`。

### 5.3 栅栏：Host / Origin 在认证之前

`src/api-request-trust.ts`：`Host` 必须是

- 回环，**或**
- 等于监听器的绑定 IP 字面量（任意端口），**或**
- 命中 `trustedHosts`（`--trusted-host`，可重复；`host:port` 精确，无端口则任意端口）。

`Origin`（若带）必须与 `Host` 同 authority，且 `sec-fetch-site: cross-site` 一律拒绝。
**校验失败 403；校验通过但未认证 401。** 顺序是"先信任、再认证"。

### 5.4 它其实支持"挂在前缀下"

`authenticatedUrl(baseUrl)` 的契约是"保留调用方的 authority 与 mount，只加本进程 token"，
并有 e2e 用例：`--public-url http://gateway.example/tools/dsh --trusted-host gateway.example`，
前面放一个**剥前缀的代理**，`/<prefix>/?token=…` 换成 cookie 后，`/<prefix>/api/...` 正常。
`public-url` 只影响"公告的 URL"，不改变绑定，也不改变栅栏——栅栏仍由 `trusted-host` 决定。

**这一条推翻了本项目早期"dsh 不支持 base path"的判断**（PLAN §5 E3）。准确说法是：
**dsh 自己不解析前缀，但它接受"代理剥前缀 + Host 保留"的部署形态**，
并且前端资源与 302 都按请求目录解析。所以 T7（飞牛统一网关）的 dsh 侧成本
比原估低得多，剩下的全在"Unix Socket + 剥前缀"这一层代理上。

### 5.5 明知能绑 `0.0.0.0`，为什么仍用 relay

§5.1 的更正说明"patch 层能绕开 CLI 绑通配"。社区里 `techysy/deepseek-harness-fnos`
正是这么做的（`0.0.0.0:28000`），也确实比 relay 少两个进程。我们不跟，理由是三条
**与实现难度无关**的事实：

| 原因 | 具体后果 |
|---|---|
| 通配是"所有接口"，不是"所有局域网口" | 同时包含 `docker0`/`br-*`/`veth`。这台 NAS 跑 docker，容器里的进程能直连 dsh 的 `/api` 与 bash 工具面 |
| 我们的跳转器本来就发令牌 | 只要容器能到 3080，就能拿到 `?token=`；再让它能到 3081，等于把 RCE 面完整交给容器网络。relay 至少让 3081 **不在**这些接口上 |
| 要写用户的 profile 文件，或用我们自己的 `--patch` | 前者会覆盖用户自己写的 `cordis.patch.yml`（techysy 的做法就是每次启动重写）；后者要额外维护一个"和 CLI 语义相反"的覆盖层，升级后行为可能悄悄变 |

代价是每个额外地址多一个监听器。这个代价是可测的、可控的；上面前两条一旦出问题
是**不可逆的**（令牌已泄露）。

---

## 6. 持久化：三种"版本"，都只前进

| 载体 | 机制 | 兼容策略 |
|---|---|---|
| 会话 | 仅追加的 `SessionEvent` 日志；JSONL v0 用 `session.jsonl[.zstd]`，v1+ 用 `session.vN.jsonl[.zstd]`；**已提交 generation 永不重命名/替换/删除** | `open` 选择最高 generation，**拒绝未来版本**，或跑一次构建时静态确定的相邻迁移链 |
| SQLite | `user_version` 不匹配直接硬失败 | 同上，单向 |
| 凭据 | `.credentials.yaml` | 丢了就要重新登录（cookie 密钥） |

**对适配的含义**：这三样都在 `$DSH_HOME`。所以封装层的铁律是
**"代码可回滚，数据只能前进"**——回滚＝装回旧 fpk + 把数据恢复到快照点，
新版本期间产生的会话只能丢弃（PLAN §7.6 已写明）。这不是我们偷懒，
是上游"generation 只增不改"的设计决定的。

---

## 7. 插件链：裸命令 `pnpm`，没有别的入口

`boot/plugin-manager` 调用 pnpm 时用的是 **`command: 'pnpm'`**（裸命令名，交给 PATH 解析），
且 `view` / `add` / `config` 会被 pnpm 再转给裸命令 `npm`。这解释了三件事：

1. 运行时只有 node 二进制时，"添加插件"必然 `spawn pnpm ENOENT`（F28）；
2. 只补 pnpm 不补 npm，`view` 会落到系统那份 npm 10.9.3，被 node 24 跑起来崩在
   minizlib（F29）；
3. pnpm 的 store 是内容寻址的，`node_modules` 里记着 `storeDir`；store 一换就
   `ERR_PNPM_UNEXPECTED_STORE`（F30）。

**对适配的含义**：插件能力不是"加个包"就能有的，它要求运行时**成套**提供
`node + pnpm + npm`，且三者的 PATH 顺序、store 指向都要在启动时对齐。
这就是 0.7.0–0.7.3 三个版本在做的事。

---

## 8. 把这些结论落到 fnOS 上

### 8.1 已经成立的映射

| dsh 侧事实 | fnOS 侧落法 | 状态 |
|---|---|---|
| 进程由外部拉起、无 systemd | `cmd/main start\|stop\|status`（0/1/3），start 自己 setsid 后台化 | ✅ |
| 一次运行一个 `$DSH_HOME` | 数据落 `@appshare/dsh/workspace/.dsh-home`（跨卸载存活） | ✅ |
| 监听必须是具体 IP | 启动时探测默认路由源地址，向导可覆盖 | ✅ |
| token 只在 `GET /` 换 cookie | 独立 launcher 占 `service_port`，302 到带 token 的地址 | ✅ |
| `--trusted-host` 可扩栅栏 | 用于多网卡入口（本轮） | 🆕 |
| 无健康端点（`/` 未认证即 401） | launcher 的 `/healthz` + TCP 探测 | ✅ |
| 插件要 pnpm+npm | 运行时成套自带，启动前置 PATH、对齐 store | ✅ |
| 会话/DB 单向 | 升级前快照 + 明确"不可降级" | ✅ |

### 8.2 剩下来的差距（按"能不能做"分类）

| 差距 | 性质 | 结论 |
|---|---|---|
| **多网卡入口**（.109 打不开） | 纯封装层 | **本轮做**：dsh 绑一个地址，其余地址靠 TCP 中继 + `--trusted-host`（§9） |
| **端口写死 3080** | 平台约束 | **不做**。`manifest.service_port` 是打包期常量，运行期改端口会让 `checkport` 与桌面入口同时错位。撞车只能重打包 |
| **进程崩溃不自愈** | 封装层可做 | 可做，但要先解决与应用中心 `stop` 的竞争；做之前不做半套（T8） |
| **外网 / DDNS / FN Connect** | 需要网关 | dsh 侧已具备条件（§5.4）；缺的是 unix-socket 剥前缀代理（T7） |
| **ARM 机型** | 构建 | 需要交叉构建 + 真机验证；内嵌 node 与原生件都是架构绑定的 |
| **体积 1GB / 6.6 万文件** | 构建 | 可瘦身，但要重跑冒烟（`.d.ts`/`map`/`test` 可能是 skill 资源） |

### 8.3 为什么 T3（端口可配）不该做

`manifest.service_port` 有三处消费方：应用中心的 `checkport` 探测、桌面入口 URL、
以及 `app/ui/config` 里的静态地址。它是**打包期**事实，不是运行期配置。
若允许用户在设置里改端口，launcher 换端口监听，平台仍按 3080 探测 → 卡片显示
"未运行"，点图标也打不开。真正的"可配端口"只能发生在打包时（`DSH_PORT` 环境变量
参与生成 manifest），那是构建参数，不是应用设置。**这件事写清楚，比做一个假开关有价值。**

---

## 9. 本轮适配：多网卡入口的实现依据

### 9.1 约束推导

```
dsh 只能绑一个具体 IP          → 其它 IP 上必须有东西接住连接
cookie 绑定 hostname:port      → 浏览器必须与 dsh 直接通信，不能经 HTTP 反代改 Host
Host 栅栏接受 trustedHosts     → 被接住的那个 IP 必须登记进 --trusted-host
WS 走 /api/remote.mux          → 接住它的东西必须透明转发 Upgrade
```

四条合起来只剩一个解：**TCP 层中继（不改字节）+ `--trusted-host <ip>:<port>`**。
中继在本机把 `eth1:3081` 的连接原样转到 `eth0:3081`，Host 头、cookie audience、
WebSocket 握手全部自洽，dsh 不需要任何改动。

### 9.2 结构

```
浏览器 ──► <任意本机IP>:3080   launcher（监听 0.0.0.0，302 到「请求所在 IP」:3081）
                                   │
                                   ▼
浏览器 ──► <请求IP>:3081        relay（TCP 中继，仅非绑定地址）
                                   │  原样字节流
                                   ▼
                              <绑定IP>:3081  dsh（trusted-host 已包含该 IP）
```

launcher 侧多一条安全约束：**302 的目标主机只能取自"本机地址白名单"**，
不能用请求里的任意 Host——否则 DNS rebinding 可以把 `?token=` 送到攻击者域名。
白名单由 `cmd/main` 探测后通过 `--allow` 传入。

### 9.3 失败模式与兜底

| 情况 | 行为 |
|---|---|
| 探测不到额外地址（单网卡 / 无 `ip` 命令） | 不启中继，不加 `--trusted-host`，与旧版完全一致 |
| 中继进程没起来 | 只影响那张网卡；绑定地址照常可用，`status` 仍为 0，日志告警 |
| 请求 Host 不在白名单 | 回退到 `state.host`（绑定地址），不泄露 token |
| 用户从回环（平台探测）访问 | 仍 302 到绑定地址；launcher 绑 `0.0.0.0` 已覆盖回环 |

---

## 10. 维护提示

- 升级 dsh 前先跑 `dsh --profile web --dump-config`，确认 `webServer.config.host/port`
  与 `connection.trustedHosts` 两项还在、字段名没变。这两处是入口方案的全部依赖。
- `--trusted-host` 的取值必须能通过"裸 authority"校验：只写 `ip` 或 `ip:port`，
  写路径（`host/path`）会让**插件 load 失败**，表现为进程秒退。
- `public-url` 只改公告，不改栅栏。T7 落地时最容易错的一步是"以为设了 public-url
  就能过 Host 校验"。

---

## 11. 版本漂移复核（2026-11-02，`0.2.1-rc.3` → `0.2.2-alpha.2`）

仓库从 `0.2.1-rc.3` 拉到 master HEAD（`ce7073d`，2026-10-30，`version = 0.2.2-alpha.2`，
距基线段 351 个提交、7994 个文件变更）。**结论先说：本文第 1–9 节的判断一条都没被推翻，
多网卡方案（0.8.0）不需要改；真正需要动作的只有一条引擎门槛。**

### 11.1 逐条复核（对着源码，不是对着文档）

| 依赖的约束 | 证据位置（HEAD） | 结果 |
|---|---|---|
| 通配地址在 CLI 被拒 | `packages/bundle/web-app/src/startup.ts:95` `isWildcardHost()` → `program.error(...)` | **不变**，连报错文案都一样。注意它只拦 `--host`，插件配置层不校验（§5.1 更正） |
| `web` 子命令参数集 | 同上 `:64–70`，与 rc.3 的同段**逐字相同** | **不变**（`--host/--port/--public-url/--trusted-host/--tls-*/--no-open`） |
| 启动地址打印格式 | `packages/bundle/web-app/src/index.ts:231` `console.log(\`dsh web: ${authenticatedUrl}\`)` | **不变**，我们抓 `?token=` 的正则仍有效 |
| 令牌只走 query | `packages/client/connection/src/browser-auth.ts:244` `url.searchParams.set(TOKEN_QUERY, launchToken)` | **不变** |
| cookie audience 绑定 hostname:port | 同文件 `:45`（README 述："HTTPS cookie 名称与签名 audience 含 `https:` scheme"） | **只增不减**：新增 scheme 维度，HTTP 场景行为不变 |
| `--profile` / `$DSH_HOME` | `apps/cli/src/args.ts:168`、`packages/boot/app-boot/src/profile.ts:5` | **不变** |
| 目录选择器从 `homedir()` 起步 | `packages/host/directory-picker-browse/src/index.ts:218` | **不变**（我们 F24 的软链前提仍成立） |
| `xdg-user-dir DOCUMENTS` 探家目录 | `packages/api/workspace-controller/src/default-directory.ts:64` | **不变**（`XDG_CONFIG_HOME` 仍必须钉死） |
| 会话格式版本 | `packages/core/session/src/types.ts:90` `SESSION_FORMAT_VERSION = 4` | **不变**（rc.3 也是 4）；最新一条持久化变更 2026-10-25 标注 `same-version` |
| 沙箱链 | `docs/subsystems/sandbox.md` 差异仅新增 `additionalWritableRoots` | **不变** |

### 11.2 变了的三件事

1. **引擎门槛（唯一需要动作的）**

   `apps/cli/package.json` / 根 `package.json` 的 `engines.node` 从
   `^22.19.0 || >=24.0.0` 收到 **`>=24.9.0`**；npm 上 `@deepseek-ai/dsh@0.2.1-rc.5`
   的包里**没有** `engines` 字段，`0.2.2-alpha.2` 有。这意味着：
   - 我们自带的 `v24.22.1` 没问题；
   - 但"能装上"不再等于"跑得起来"——npm 对 engines 默认只告警。已在
     `build.sh` 加打包期硬门槛，`probe/05` 加了装机期数值判定。
   - 回退路径（没带 node、用 `/var/apps/nodejs_v24`）也要 ≥24.9，验收时一并看。

2. **依赖 +5，但都不进 web 形态**

   `0.2.1-rc.5`(86) → `0.2.2-alpha.2`(91)。新增
   `dsh-official-bundles`、`dsh-experimental-liveshare`、`dsh-personalized-recommendations`、
   `dsh-experimental-forge-bundle`（+1 个传递依赖）。四个包都是**自带 `cordis.patch.yml`
   的独立 bundle**，`packages/bundle/web-app/cordis.patch.yml` 里没有任何一行挂载它们
   → **装上但不激活**。对运行期行为零影响，对包体积是纯增量（下次装机量一下）。

3. **用户可见功能换血，但不碰我们的接口**

   `apply-patch` 工具、自动化事件触发、Forge Git 面板、调度工具改名
   （`schedule_update/delete` → `schedule_edit`）、Liveshare 会话共享。
   这些是产品面变化，`web` 部署参数与协议面没动。

### 11.3 升级决策（保持钉 `0.2.1-rc.5`）

npm dist-tags 本次实测：`latest = next = 0.2.1-rc.5`，`alpha = 0.2.2-alpha.2`。
即 0.2.2 线仍是 **alpha**，未转 rc。

| 选项 | 判断 |
|---|---|
| 跟随 `alpha`（0.2.2-alpha.2） | ⏸ 不做。理由是"给 NAS 用户发的包不该跑在 alpha 上"，且新增 4 个 bundle 会让体积再涨一截；等功能面稳定（转 rc）再跟 |
| 保持 `0.2.1-rc.5`（`latest`） | ✅ 当前选择。CLI 面、协议面、会话格式三者都与我们验收过的基线一致，升级风险最低 |
| 用 git 源码自建 | ⏸ 不做，见 PLAN §A |

**真要升 0.2.2 时，只有三件事要重验**（其余按 §11.1 的表抽查即可）：
`--dump-config` 里 `webServer/connection` 两行还在 → `dsh web:` 那行日志格式没变 →
带 node 版本 ≥24.9 打出包、装机跑 `probe/05`。

### 11.4 一个被否掉的"机会"

新出现的 `sandbox-policy.additionalWritableRoots`（`docs/config-catalog.md:2922`，
web 形态走 base bundle 的默认值 `mode: workspace-write` + `workspaceRoot: process.cwd()`）
看起来能解 F23/F24，**实际不能**：它管的是"沙箱允许写哪些根"，而 F23/F24 卡的是
"fnOS 授权"与"选择器能不能点到那个目录"。会话 cwd 一旦就是用户选的工作区，
`workspace-write` 本来就允许写。**不要为它排期**，否则是拿一个配置项去解一个权限/导航问题。

### 11.5 顺手验到的一条：为什么"只换 runtime、保留 profile"是安全的

我们的升级策略一直是"清 `runtime`、留 `$DSH_HOME`"（§7.2）。这次顺着查了它的结构依据：

```ts
// packages/boot/app-boot/src/profile.ts:205-211
const manifest = {
  name: `dsh-profile-${basename(dir)}`,
  private: true,
  dependencies: {},                                  // ← 空的
  dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'] } },
}
```

三个推论，正好解释了我们踩过的每一件事：

| 观察到的事实 | 结构原因 |
|---|---|
| 换 dsh 版本不需要重建 profile | `dependencies` 为空：官方 bundle 从**安装目录**解析，不落在 profile 里；profile 只装第三方插件 |
| 升级后用户的插件还在 | 插件确实在 `profiles/web/node_modules`，与 runtime 分离 |
| 但插件可能"版本不兼容"告警 | 插件 `peerDependencies` 对的是旧 dsh；`plugin-manager` 按 `evaluatePluginCompatibility` 判，不是崩溃 |
| web 模板从 rc.3 到现在没变 | 两边都是 `['dsh-base','dsh-web-app']`（rc.3 在 `app-boot`，现移到 `dsh-official-bundles`，**内容相同**） |

所以"只换 runtime"不是权宜之计，而是与上游的 profile 模型同构。**唯一要留意的例外**：
上游若哪天把新 bundle 加进 web 模板，老 profile 的 `bundles` 列表不会自动补上
（`initProfile` 只在 `package.json` 不存在时写）。真遇到"新功能看不到"，
删掉 `profiles/web/package.json` 的 `dsh.profile.bundles` 或整个 profile 重建即可——
但**先备份**，重建会丢用户的 `cordis.patch.yml`。
