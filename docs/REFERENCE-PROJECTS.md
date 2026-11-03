# 社区同类项目参考

状态：**调研稿 v1.0（2026-11-02）**　范围：公开可查的「飞牛 fnOS + DeepSeek Harness」
封装项目。本文只记录**能被源码或文档复核**的说法；社区作者的结论与我们对上游源码的
实测不一致时，以源码为准并标注差异。

> 用途：给本项目的技术选型做外部对照。凡是「别人这么做」就照抄的地方，都要先回答
> 一句「他的 dsh 版本和我们的差多少、他解决的问题我们还存不存在」。

---

## 1. 五个项目

| 项目 | 协议 / 热度 | dsh 基线 | 运行身份 | 入口形态 | 绑定方式 |
|---|---|---|---|---|---|
| [techysy/deepseek-harness-fnos](https://github.com/techysy/deepseek-harness-fnos) | MIT / 83★ | 随上游，`manifest.version` = 上游版本（发布时 0.1.7-rc.2 线） | 专用用户 `dsh`（`run-as: package`） | 网关 `/app/dsh` + 局域网 `28000` + 面板 `28001` | **`cordis.patch.yml` 覆盖成 `0.0.0.0:28000`** |
| [10000ge10000/deepseek-harness-fpk](https://github.com/10000ge10000/deepseek-harness-fpk) | MIT / 45★ | 0.1.5-rc.1 | 未在 README 声明 | 桌面 iframe + 透明反代 3080 | 透明反代到内部 3081（dsh 本身仍绑具体地址） |
| [YUNXI-fi/DeepSeek-Harness-fnos](https://github.com/YUNXI-fi/DeepSeek-Harness-fnos) | 未标注 / — | 0.1.0-rc.6 | 专用用户 `deepseekharness`（`run-as: package`） | 网关 iframe：`app.sock` → `127.0.0.1:3080` | 只绑回环，靠 unix socket 代理对外 |
| [lu-peifeng/fnos-deepseek-harness-manager](https://gitee.com/lu-peifeng/fnos-deepseek-harness-manager)（Gitee） | 未标注 / — | 0.1.0-rc.7（首次启动 `npm i -g` 现装） | **root**（`config/privilege`） | 管理页 + `/ds/*` 反代 | `127.0.0.1:{port}` |
| [fnosp/fnos-dsh](https://github.com/fnosp/fnos-dsh) | Apache-2.0 / — | 未固定（monorepo 跟随） | — | 网关 + 插件生态 | — |

我们自己（`dsh` 0.8.1）对照位：**非 root 专用用户 `dsh`**、入口 `type: url` 直连
`3080`、`launcher` 302 到 `3081`、其余本机地址由 `relay` 在 TCP 层接住、
数据落 `@appshare/dsh/.dsh-home`（跨卸载存活）、单架构 `x86`、包内 1015MB。

**第一个结论**：能查到基线的四个项目**全部是 `0.1.x`**（最高的 `techysy` 也只到
0.1.7-rc.2 线，`fnosp` 未固定版本）。我们钉的是 `0.2.1-rc.5`，中间隔着
「浏览器 token 鉴权」「目录选择器重写」「web-app 组合包拆分」几次改动。
**他们代码里的运行时补丁，一半以上是在补我们已经没有的问题**。照抄会引入新风险，不是省事。

---

## 2. 四种入口/绑定路线

### 2.1 CLI `--host` + 多地址接住（本项目）

```
launcher 0.0.0.0:3080 ──302──► <请求来源IP>:3081
relay    <其余IP>:3081 ──TCP──► <主地址>:3081
dsh      <主地址>:3081  +  --trusted-host <其余IP>:3081
```

- 优点：dsh 只绑一个具体地址，暴露面 = 我们枚举出来的地址；
  不改上游任何文件，升级不用重新打补丁；Host/cookie 全程不变。
- 缺点：多两个进程；地址变化要重启；**没有网关，外网用不了**。

### 2.2 patch 层绑 `0.0.0.0`（techysy）

`cmd/main` 每次启动写 `$DSH_HOME/profiles/web/cordis.patch.yml`：

```yaml
# 语义等价，非原文
- id: webserver
  config:
    host: '0.0.0.0'
    port: 28000
```

**这条能成立，是因为上游的通配校验只装在 CLI 上**（见 §3.1）。优点是一个进程搞定
所有网卡，连 IP 变化都不用管；缺点是所有接口（含 `docker0`/`veth`）一起暴露，
而且每次启动重写的是**用户自己的** profile 文件。

它的鉴权模型也随之变成「围栏即认证」：patch 掉 `isAuthenticated`，让通过
Host/Origin 栅栏的请求直接放行。作者在 README 里明确写了
「请勿把 28000 / 28001 暴露到不受信任的网络」——这句话本身就是这种模型的风险说明。

### 2.3 unix socket + 剥前缀代理（YUNXI）

```
浏览器 → 飞牛网关(/app/deepseekharness) → app.sock
       → app/proxy.js（剥前缀、重写响应体绝对路径、WS 透传）→ 127.0.0.1:3080
```

这是**唯一真正解决了 T7（外网/FN Connect）**的路线：dsh 只监听回环，对外零端口。
代价是代理要改写响应体里的 `/assets`、`/api` 绝对路径——上游一旦换资源路径，
代理就得跟着改。

### 2.4 透明反代（10000ge10000）

对外 3080、内部 3081，加「安全上下文 Polyfill」与 iframe / `SameSite=Lax` 适配。
它回避了「dsh 只认一个地址」的问题，但反代必须保住 Host（否则 cookie audience
与栅栏都会失配），实现细节 README 未展开。

---

## 3. 三条被复核推翻/修正的说法

这一节是本文最有用的部分：**社区文档里的经验，有一半已经不适用于 0.2.x**。

### 3.1 「通配地址在 load 阶段被拒绝」——只对 CLI 成立

| 位置 | 事实 |
|---|---|
| `packages/bundle/web-app/src/startup.ts:95` | `isWildcardHost(options.host)` → `program.error(...)`，**只校验 `--host`** |
| `packages/bundle/web-app/cordis.patch.yml:179` | `host: !!js ctx.webStartup.host ?? '127.0.0.1'`，是**普通配置值** |
| `packages/host/webserver/src/index.ts:621` | `server.listen(port, config.host)`，**没有二次校验** |

所以：CLI 挡得住，patch 层挡不住。我们此前在
[HARNESS-ARCHITECTURE §5.1](HARNESS-ARCHITECTURE.md) 与 PLAN 里写的
「架构层拒绝、不能靠 patch」是**不准确的**，已更正。
不用它的理由见 [HARNESS-ARCHITECTURE §5.5](HARNESS-ARCHITECTURE.md)（暴露面，不是可行性）。

### 3.2 「`--trusted-host` 重复写只保留最后一个」——0.2.x 不成立

techysy 的 README 这么写，并按「一次传多个值」实现。上游单元测试
`packages/bundle/web-app/tests/startup.spec.ts:100-117` 的期望是**累积**：

```ts
'--trusted-host', 'lab.internal', 'lab-2.internal',
'--trusted-host', '10.0.0.9',
// → trustedHosts: ['lab.internal', 'lab-2.internal', '10.0.0.9']
```

我们 `cmd/main` 是 `for _ip in ...; do trusted+=(--trusted-host "$_ip:$port"); done`，
**写法正确，不需要改**。这类差异多半来自他们当时用的版本或 shell 引号，不能当通则。

### 3.3 「必须注入 `crypto.randomUUID` Polyfill」——我们这版不需要

10000ge10000 的构建流程会往客户端注入 `crypto.randomUUID` polyfill，理由是局域网
HTTP 是非安全上下文。但 `0.2.x` 已经把它收进
`packages/util/crypto/src/index.ts`：用 **`crypto.getRandomValues`**（无安全上下文限制）
自己拼 v4 UUID，注释里就写着「a page served over plain HTTP on a LAN address has no
such method」。我们链上其余两个安全上下文 API 也不构成阻塞：

| API | 0.2.x 的处置 | 在 `http://192.168.x.x` 上的结果 |
|---|---|---|
| `crypto.randomUUID` | 改由 `getRandomValues` 实现 | ✅ 正常 |
| `crypto.subtle.digest` | 只在 `desktop !== undefined`（原生壳）分支用 | ✅ 浏览器路径不经过 |
| `navigator.clipboard` | `ui-primitives/clipboard.ts` 有 `execCommand('copy')` 回退 | 🟡 主复制按钮可用；右键菜单里几处直接调 `navigator.clipboard` 的会静默失败 |

所以 **0.8.1 不需要补 Polyfill**；要补也只是「右键复制路径」这类小按钮的体验，
优先级低于网关。

---

## 4. 采纳 / 不采纳

| 别人的做法 | 决定 | 理由 |
|---|---|---|
| 网关 unix socket + 剥前缀（YUNXI） | ✅ **采纳为 T7 的实现路线** | 上游 `--public-url` 已支持前缀（有 e2e），比它改写响应体更稳：我们只需写一个「收 socket、剥前缀、转 TCP」的代理，不必碰 HTML/JS |
| `trusted_hosts.conf` 管理 FN Connect / DDNS 域名（techysy） | ✅ 采纳思路，随 T7 一起做 | 现在 launcher 的白名单只认本机 IP，DDNS 域名会被回退成本地 IP，远端必然打不开 |
| 双架构各自打包、按 `uname -m` 出包 | ✅ 采纳（本轮落地构建期门禁） | 见 §5 |
| 管理面板（状态/日志/插件/热更新） | ⏸ 不做 | 我们已有 `probe/05` 与 `var/info.log`；再养一个 Web 面板等于多一个受攻击面，且要单独鉴权 |
| 运行时 patch `isAuthenticated` 免 401 | ❌ 拒绝 | 我们靠 launcher 302 带 token 换 cookie，**认证没有被关掉**；他们的补丁每次升级都要重打，且等效取消认证 |
| patch `webserver.config.host = 0.0.0.0` | ❌ 拒绝（可做但不做） | 见 §3.1 与 HARNESS-ARCHITECTURE §5.5：会连容器网桥一起暴露，而我们的 launcher 会发令牌 |
| 首次启动 `npm i -g` 现装 dsh | ❌ 拒绝 | 断网即不可用、版本不可复现、供应链不可审计；我们离线内置 |
| 以 root 运行 | ❌ 拒绝 | 我们是 `run-as: package` + 专用用户 `dsh` |
| `crypto.randomUUID` Polyfill | ❌ 不需要 | 见 §3.3 |

---

## 5. 本轮唯一的代码改动：架构门禁

对照下来，最容易被忽略、后果又最难受的差异是**架构**：三个项目都出 x86 + ARM
两套包（techysy 还注明 ARM 原生模块要求 glibc ≥ 2.28，且作者未在 ARM 实机自动化测试）。
我们只有 `platform="x86"`，而 `build.sh` 的 node 与 `node_modules` **都取自打包机**
（`NODE_SRC` + 本机 npm）——这意味着「在 x86 上打出来的包只能在 x86 上跑」。

以前没有任何检查：在 ARM NAS 上跑 `bash build.sh` 会得到一个 `platform=x86` 的包，
装上去要么被应用中心拒绝，要么装上了跑不起来。现在 `build.sh` 在版本检查后加了一段：

```
uname -m  →  x86_64|amd64 → x86 ；aarch64|arm64 → arm ；其它 → 不猜
manifest.platform ≠ 期望值 → die（附「请在对应架构机器上各打一次」）
```

顺带把 `platform="all"` 也挡掉：fnOS 规范明确「含架构二进制时不能用 `all`」，
而我们的包里就有 node 二进制。

---

## 6. 仍然落后的地方（按值不值得做排序）

| 差距 | 影响 | 现状 |
|---|---|---|
| **T7 未接网关** | 外网、FN Connect、DDNS 全部不可用；只能 VPN/Tailscale | 路线已定（§2.3 + `--public-url`），未实现 |
| 只有 x86 | ARM 机型（部分 RK/Allwinner 设备）装不上 | 门禁已加，出包仍需在 ARM 机器上打 |
| `allUsers: true` | 任何飞牛账号都能在桌面看到并打开（dsh 的 bash 工具以应用用户执行） | 社区两个项目都设 `false`。我们没改：它只影响图标可见性，挡不住直接访问端口，价值有限；要改是一行 |
| 无热更新 | 升级要手动装 fpk | 不做：热更新需要 sudo 白名单，等于给应用一条提权通道 |
| 包体 1015MB | 安装慢、占空间 | 有瘦身空间（见 HARNESS-FEATURES），但要重跑冒烟 |

---

## 7. 复核方法（可重复）

```bash
# 别人的结论 vs 我们的上游源码
grep -rn "isWildcardHost" --include=*.ts apps packages          # 闸门装在哪一层
grep -n "host: !!js ctx.webStartup.host" packages/bundle/web-app/cordis.patch.yml
grep -n "trustedHosts:" packages/bundle/web-app/tests/startup.spec.ts
sed -n '1,42p' packages/util/crypto/src/index.ts                # 安全上下文
```

三条都能在一分钟内跑完，且结论不受社区文档版本影响——**以源码为准**。
