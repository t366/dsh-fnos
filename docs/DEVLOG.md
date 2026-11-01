# 开发记录

按时间顺序记「做了什么、为什么这么做、怎么验证的」。只记决策与结果，不贴大段代码——
代码在 git 里，踩坑的根因在 [ISSUES.md](ISSUES.md)。

**记录口径**：2026-10-27 建仓之前的回合发生在当天白天，没有 git 提交可查，依据是当时的
真机输出与 [PLAN.md](../PLAN.md) §2 的事实核查章节；建仓之后的记录按提交号索引。

环境：飞牛 fnOS（主机名 `FNOS`，11.7GB 内存 / 8 核，网卡 `192.168.0.109` 无线、
`192.168.0.114` OVS）；开发机 Windows + Git Bash；仓库 `http://192.168.0.114:3000/T366/dsh-fnos`。

---

## 阶段 0：能不能不用 Docker（2026-10-27 上午）

先确认技术前提，避免走错路：

| 检查 | 结果 |
|---|---|
| fpk 是否支持自定义进程 | 支持。`cmd/main start\|stop\|status`，**没有 systemd 集成** |
| Landlock / bwrap（dsh 的沙箱依赖） | 均可用，root 与 `nobody` 下都通过 |
| 系统 Node | `nodejs_v24` = 24.22.1-1，够用，但**不在 PATH** |
| dsh 是否支持局域网 | 支持 `--host <IP>`，但**拒绝 `0.0.0.0`** |
| dsh 是否需要 Docker | 不需要 |

结论：**能做**。剩下的是工程问题（体积、入口、升级），不是可行性问题。

## 阶段 1：真机评估与冒烟（同日上午/中午）

- 阶段一（只读体检）**19 OK / 0 FAIL**；阶段二（冒烟）**11 OK / 0 FAIL**。
- dsh `0.2.1-rc.2` 安装体积 **866MB / 63053 个文件**，冷启约 **3s**，RSS **406MB**。
- 这一步定了两件事：**运行时自带 Node**（系统那个是"可被卸载的商店应用"，只省 13% 体积，
  换来一个隐性依赖，不划算）；**数据必须落共享目录**（后面 P6 才验证原因）。

## 阶段 2：M1 骨架包 0.1.0（17:10）

用占位服务（stub）先把安装链路跑通，不背 990MB 的包。

装成后立刻暴露三个问题，全部记进 [ISSUES](ISSUES.md)：

1. `status` 返回 **3**，但进程在跑（F1，路径写法比对）；
2. 打包后 `manifest` 被 **fnpack 重写**，探针 `grep '^service_port='` 静默取空（P4）；
3. `config/`、`wizard/` 装完变 **644**（P5）。

修完复验：`PASS 23 / WARN 3 / FAIL 0`，`status=0`，监听 `192.168.0.114:3080`，HTTP 200。

## 阶段 3：升级到底怎么做（17:25–17:30）——推翻了原计划

原方案假定「fpk 覆盖升级」。实测推翻了它：

- `install-fpk` 对已装应用只回 `is installed`，**没有 force/upgrade**，`upgrade_*` 钩子走不到（P1）；
- `install-local` 会先卸载，但触发平台缺陷 **10237**（临时目录丢 x 位）（P3）；
- CLI `uninstall` 拒绝手动安装的应用，**只能走 Web UI**（P2）。

于是升级流程改成「界面卸载（保留）+ 界面手动安装」，并在 `build.sh` 里加了
「包版本 vs 已装版本」的比对警告，避免同版本白装一次。

> 这期间 `probe/06-upgrade-truth.sh` 出现过一次**假阳性**：卸载被拒、脚本仍判「数据全存活」。
> 现在它带门禁——没看到 `/var/apps/dsh` 消失就判实验无效。教训：**实验脚本必须能证明自己真的做了那件事**。

## 阶段 4：0.2.0——把数据搬到共享目录（17:30–17:37）

用界面卸载做了一次真实实验，得到 P6 那张表：`@appdata` 目录还在但**内容被清空**，
`@appshare` 被 `chmod 000` 但**内部文件存活**。

所以 0.2.0 把 `dsh-home` 与配置副本搬到共享目录 `.dsh-home`（700），配置双写
（`@appconf` + 副本），读取时先 `@appconf` 再副本。重装后会话与 Key 恢复，验证通过。

## 阶段 5：0.4.0——入口跳转器（19:29 建仓 ~ 19:36）

**用户的原话**：「每次通过命令获取启动令牌很麻烦」。查过 dsh 的 web profile：只有
`--host/--port/--tls-cert/--tls-key/--public-url/--trusted-host/--no-open`，
**没有固定令牌开关**，令牌每次启动随机 mint。

方案按用户选择走 **B：跳转器 + 设备白名单**：

- 跳转器占 `service_port`（3080），dsh 退到 3081；
- 未配对访客只看到粘贴页，不泄露任何信息；
- 令牌**不落盘解析**：拿去请求 `127.0.0.1:3081`，回 3xx 即通过；
- 配对成功签 `dsh_gate`（HttpOnly / SameSite=Lax / 180 天 / HMAC），密钥 `@appdata/launcher-secret`（600）；
- 同 IP 5 次失败 → 429，窗口 10 分钟；
- 只 `302`，**不代理业务流量**（代理要改 Host，会破坏 dsh 的 Host/Origin 栅栏）。

同时把仓库建起来：`d54e6db` 初始提交（38 文件 / 400KB），`.gitattributes` 钉 LF，
`cmd/*` 补可执行位，推送到 `T366/dsh-fnos`。

随后 `2d50403` 把运行时钉到 **dsh 0.2.1-rc.3**：npm `latest` 是 rc.2、`next` 是 rc.4，
但 rc.4 的 5 个包与 rc.3 除版本号外内容完全一致（无 GitHub release），判定为无变更重发；
GitHub 最新 release 与官方桌面版都是 rc.3。

## 阶段 6：0.5.0——点图标即进（19:51–19:53）

0.4.0 仍需「首次粘一次令牌」。用户要求去掉这一步，于是跳转器**自己读本次启动的令牌**：

- `cmd/main` 启动 dsh 后从**本次新增日志**抓 `token=`（F2 的教训），写 `launcher.json`（600）；
- 跳转器每次请求现读，`302` 到 `http://<绑定IP>:3081/?token=…`；
- 只有内网来源（含 Tailscale `100.64/10`）自动放行，**公网来源仍走配对**；
- 设置里新增「入口方式」，可切回 `pair`。

同一批还改了流程：`build.sh` 内置自测（失败即中止）、打完自动复制 fpk 到共享目录，
安装/卸载全部收敛到界面（`53af194` 修正了顺序：**先下载 fpk 再卸载**，否则共享目录被
`chmod 000` 就打不开了）。

## 阶段 7：两次打包失败，两次修复（20:01 / 20:07）

两次 `build.sh full` 都卡在同一条断言上：`auto：上游接受这条令牌（303）（期望 303，实际 000）`。
看起来像产品缺陷，实际两次都是**测试自身的问题**：

| 提交 | 根因 | 修法 |
|---|---|---|
| `9adb7be` | 假上游还没 `listen()`，第一发 curl 被拒 | `wait_up()` 轮询就绪 + 重试 + 现场诊断 |
| `cfd363c` | `Location` 残留 `\r`：fnOS 的 sed 不认 `\r` 转义 | `tr -d '\r'` + bash 裁尾随空白（三处） |

第二次的判断依据值得记住：在同一段里 `pair：正确令牌 → 302` 是**通过**的，而那条要求跳转器
主动去请求同一个上游——所以上游是好的，问题在别处。

复现实验（开发机上）：

```console
$ curl -s -o /dev/null -w '%{http_code}' "http://…/?token=A"$'\r'
000                    # exit 3；加 -s 时连报错都看不到
```

`e5a148e` 把这个坑写进了 [PLAN §5.1.1](../PLAN.md)。

## 阶段 8：0.5.0 安全承诺与健壮性（20:38–20:46）

起因是对照社区方案做审查（dshbase / `techysy/deepseek-harness-fnos`、
`10000ge10000/deepseek-harness-fpk`、论坛帖 70194），发现我们 README 里
「公网来源不会被自动放行，这条写在代码里」**在有反向代理时不成立**：

- `launcher` 只看 `socket.remoteAddress`，本机反代会让它变成 `127.0.0.1`，
  于是公网访客被当成内网直连、自动拿到带令牌的跳转；
- 上游文档明确 web profile 是 loopback 服务，跨机访问应由反代 + `--public-url` /
  `--trusted-host` 负责，我们的 `--host <LAN IP>` 是权宜（换来 T6 双网卡问题）。

同一轮把几处确定性的坑一起修了：

| 编号 | 改动 | 验证 |
|---|---|---|
| F9 | `viaProxy()`：出现任何代理头就不自动放行，落配对页 | 本地起假上游：直连 302、带 `X-Forwarded-For`/`X-Real-IP` 均 200 |
| F10 | token 抓取不再写死字符集（`.`/`+`/`%`/`=` 都保留） | token `abc.def-ghi_jkl` → Location 完整、上游 303 |
| F11 | `force_rm()`：先恢复权限再删，删不掉明确告知 | 语法检查；真机待验 |
| F12 | 同版本打包默认 `die`，`DSH_ALLOW_SAME_VERSION=1` 放行 | 语法检查 |
| F13 | selftest 用 `cygpath -u` 去掉盘符冒号、自动取 PATH 的 node | 直接跑：**29 通过 / 22 跳过 / 0 失败**（原 22/22/7） |

`selftest.sh` 同步加了「带 X-Forwarded-For 不自动跳转」的回归项。本轮没有动
`cmd/main` 的进程编排，也没有实现「先换 cookie 再转发」——后者取决于 T2 的真机结论。

## 阶段 9：第三次打包，暴露「残留运行时」（20:55）

推上 Gitea 后在 NAS 上重跑，自测第一次跑满 Linux 全量断言：

```console
== HTTP 探测
  FAIL  GET / 返回 200（期望 200，实际 302）
通过 54 / 跳过 0 / 失败 1
```

**不是入口坏了，是这一段跑成了 dsh 模式。** `detect_mode()` 只看
`runtime/app/node_modules/@deepseek-ai/dsh/package.json` 在不在；而源码树里残留着
上一次 `build.sh full` 装出来的 `app/runtime/app`、`app/runtime/node`——这两个目录
在 `.gitignore` 里，`git pull` 不会清。于是沙箱带着 dsh 包起步：跳转器占 13080、
dsh 退到 13081，`GET 13080/` 返回 302，而该段断言写的是骨架模式的 200。

铁证在日志里：dsh 模式段打印 `node=…/target/runtime/node/bin/node`。没有残留时
`find_node()` 只会找到系统的 `/var/apps/nodejs_v24/...`。

| 编号 | 改动 | 验证 |
|---|---|---|
| F14 | 沙箱复制后 `rm -rf target/runtime/app`（只删副本）+ 新增断言「本段跑的是骨架模式」 | 人为放置残留后自测：打印「已移除残留」、`GET /` 200，**30 通过 / 22 跳过 / 0 失败** |

这个坑的教训比修法重要：**`.gitignore` 的构建产物不会随 `git pull` 消失**，
而自测的假设建立在「源码树是干净的」之上。凡是「按目录存在性判断分支」的地方，
都要先问一句「这个目录会不会是残留」。

## 阶段 10：0.5.0 装上真机，T1 / T2 关闭（21:09–21:14）

F14 修复后重新打包，自测通过，随后界面卸载（保留）→ 手动安装。**第一次把 0.5.0 装到真机上。**

```console
probe/05   PASS 33 / WARN 1 / FAIL 0
probe/07   PASS 10 / FAIL 0（auto-ok）
healthz    {"ok":true,"ready":true,"auto":true,"mode":"auto"}
```

关键事实：

| 项 | 实测 |
|---|---|
| 版本 | `0.5.0`；`target → /vol1/@appcenter/dsh`；bundled dsh `0.2.1-rc.3`、node `v24.22.1` |
| 权限 | 9 个 `cmd/*` 全 755；应用用户 `dsh` uid=971；`dsh-home` 700、`settings.conf` 600 |
| 端口 | 三处一致 3080；launcher 绑 `192.168.0.114:3080`、dsh 绑 `:3081`；3081 裸访问仍 401 |
| 安装耗时 | `install_init` 21:09:29 → `ok` 21:09:51，**解包完成后约 22 秒**可用 |
| F9 | 外部实测：直连 302；`X-Forwarded-For` / `X-Real-IP` / `Forwarded` 均 200 配对页 |

**T2 顺手关掉**（这条悬了整轮）：`probe/07` 的「第二次点击」用的是不带 cookie 的独立
curl，仍然 303 —— 说明**令牌可复用，不是一次性的**；重启前的 dsh cookie 也能继续用（200）。
所以「302 把令牌写进 `Location`」的设计成立，不用改成「先换 cookie 再转发」。
脚本注释里那句「带 jar 测就是假阳性」这次起了作用。

本轮顺带修的小问题与新发现的测量坑：

| 编号 | 内容 |
|---|---|
| F15 | 配对密钥 700 不自愈：`loadSecret()` 读到旧文件直接返回，早期版本留下的宽权限永远不改。改为读到即 `chmod 600` |
| — | `du -sh /var/apps/dsh` 只有 132K/17 文件——`target`、`var`、`etc` 都是软链，`du` 不跟随。真实体积要 `du /vol1/@appcenter/dsh` |
| — | `curl 127.0.0.1:3080/healthz` 返回空：launcher 绑的是局域网 IP。README 与 RUNBOOK 的排错命令已改成先解析 `DSH_BIND` |

## 阶段 11：体积补测 + 一个我自己造成的坑（21:21）

**T5 数据补齐**：`du -sh /vol1/@appcenter/dsh` = **957M**，`find … -type f | wc -l` = **63056**。
包 990MB、装完略小，与预估一致；`install_init` 卡「≥1.5GB 可用」在 957M 面前余量够，
但**解包瞬间的峰值仍未测**（要下次装包时用 `df` 轮询才有数据）。

**用户反馈「应用中心 dsh 只有打开和卸载」**，这直接否掉了我上一轮让他「在应用中心停一下再启动」
的验证方案——没有停止按钮就没有这条路径。三个候选原因写进 T10（manifest 丢了 `ctl_stop`、
平台把运行中判成已停止、或停止入口在详情页的「⋯」里），并加了定性命令。
`probe/05` 从此断言 `ctl_stop=true`，下次验收会直接暴露是哪种。

**同时发现两件比按钮更严重的事**：

1. 上一轮 `probe/07` 是我让用户在 **root** 下跑的。它会 `stop` + `start` 一次，
   于是 dsh 以 root 启动、把 `dsh-home` 里的 `-wal` 与会话库写成了 root 所有。
   应用中心下次以 `dsh`(971) 启动时对这些文件没有写权限——症状是「会话凭空少了」，
   而且不报错。改为 `probe/07` 在 root 下用 `su` 降权执行，并在重启后
   `find "$HOMEDIR" -user root` 自检（F16）。
2. 「安装时启动」用 `/vol1/@appshare/dsh/workspace`，「手工启动」走回退路径
   `/var/apps/dsh/cmd/../shares/workspace`。两者必须指向同一目录，否则就是两套 dsh-home、
   两套会话库，其中一套还会随卸载消失。`probe/05` 新增断言：比对 `readlink -f` 后的结果。

这三条的共同点是：**验收脚本自己会改变被测系统**。以后凡是让用户跑会 `start` 的探针，
都得先问一句「它是以谁的身份启动的、start 之后路径还是原来那个吗」。

## 阶段 12：按钮消失的真因在「回环没有监听」（21:26）

用户在应用中心只看到「打开 / 卸载」，没有停止。按 T10 的三个候选逐条排除：

```console
ctl_stop = true        ← 不是 manifest 丢键
status   rc=0          ← 不是我们的 status 报错
两套 workspace         ← readlink -f 后同一条路径，只有一个 dsh-home
dsh-home root 文件     ← 1 个（probe/07 以 root 重启造成，F16 的现场）
```

于是剩最后一条自洽解释：**launcher 只绑局域网地址**，平台对 `service_port` 的本地探测
（回环）拿不到响应，于是按「未运行」渲染，启停入口跟着消失。这个坑其实早就露过头——
我之前让用户 `curl 127.0.0.1:3080/healthz` 得到空，当时只改了文档，没动根因。

**F17 修法**：`--host` 不是回环时，额外在 `127.0.0.1` 上再起一个监听，共用同一个 handler；
回环监听失败只记日志，不影响局域网入口。同时把 handler 从 `http.createServer(async …)`
里提出来，两个 server 共用。

**验证**：自测新增两条（用 `127.0.0.2` 冒充非回环）——「给 LAN 地址时回环也监听」与
「原地址仍可访问」，Windows 上 **32 通过 / 22 跳过 / 0 失败**；NAS 上预期 **58**。
真机上按钮是否出现，得等下次装包才知道，所以 T10 仍标未关闭。

顺带确认 `appcenter-cli` 1.0.2 有 `start` / `stop` / `status`，
「没有停止按钮时怎么重启」终于有确定答案，不用再靠 `su` 兜底。

## 阶段 13：10330 不是谜，是 stop 撒了谎（21:31）

按 F16 的清理步骤执行时，`appcenter-cli stop dsh` 回 `stop success`，
紧接着 `appcenter-cli start dsh` 回 `something wrong with appcenter: code 10330`，
而且 `var/dsh.pid` 已经不存在了。

链条很清楚：那个 dsh 是**我在 root 下用 probe/07 起的**；应用用户 `dsh` 的 `kill`
对它是 EPERM，静默失败；`do_stopf()` 不看结果，照样删 pidfile、记 done、`return 0`。
于是「pidfile 没了 + status 报未运行 + 端口还被占着」同时成立，`start` 必然 EADDRINUSE，
平台把它折叠成 10330，对话框里一个字的原因都没有。

**F18 修法**（都在 `cmd/main`）：

- 新增 `is_alive()`（排除 `Z` 僵尸态），stop 收尾据此复核；
- 仍活着 → 记 FAILED、写清「谁占着、当前身份没权限」到 `TRIM_TEMP_LOGFILE`、保留 pidfile、`return 1`；
- `do_stop()` 汇总结果，失败时不再删 `launcher.json`（留着比清空更有助排查）；
- `stop` 子命令 `exit $?`；start 的 EADDRINUSE 文案补上「别人留下的进程」这一句。

自测 `32 通过 / 22 跳过 / 0 失败`（stop 相关 6 项全绿）。

教训：**「停止」这种破坏性操作必须验证结果**。原代码只保证「发了信号」，
不保证「进程没了」——而平台只会给一个错误码，用户和我都会先怀疑平台。

## 阶段 14：确认实例归属，版本提到 0.6.0（23:37–23:40）

**先解决「现在跑的是谁」**。外部探测没有信息量——`3080/healthz` 返 200、`3081` 返 401，
root 残留与平台拉起的实例给出完全一样的响应。判据只能是端口属主：

```console
LISTEN 192.168.0.114:3081  pid=3359059
LISTEN 192.168.0.114:3080  pid=3359039
dsh  …/dsh/lib/bin.js --profile web --host 192.168.0.114 --port 3081
```

pidfile 在、属主 `dsh`、命令行与 `--port 3081` 对得上，PID 是新一轮（`3359xxx`，
root 那批是 `3280xxx`）——**平台拉起、应用用户运行**，P0 关闭。

**唯一残留**：`dsh-home` 里 1 个 root 所有的旧会话文件（F16 现场）。23:41 用
`find … -user root -exec chown dsh:AppUsers {} +` 改归属，复查 `find … -user root | wc -l` 得 **0**。

**版本提到 0.6.0**：`manifest` 的 `version` 与 `changelog` 一起改，把 F15 / F17 / F18
三项写进面向用户的话（停止按钮回来、stop 失败会说原因、密钥权限自动收敛）。
`build.sh` 的同版本守卫（F12）要求必须先提版本，否则直接 `die`——这一步是装包的前置条件。

**RUNBOOK 同步**：第 0 步按「已装 0.5.0 → 直接打 0.6.0」改写；第 4 步新增 4.0 磁盘采样
（`df` 每 2 秒一行，装完取最小可用，补 T5 唯一的缺口）；第 5 步把
`curl 127.0.0.1:3080/healthz` 从「会得到空响应，别用」改成**验收项**（期望 200）——
F17 之后这条才算有意义。


## 阶段 15：把待办收敛到一处（23:55）

文档走到这一步的问题是**同一件事散在四个地方**：ISSUES 的「当前剩余问题」、PLAN §10 的
26 项待实测、DEVLOG 末尾的「下一步」、README 的「已知问题」。它们开始互相矛盾——
PLAN §10 里还列着"大 fpk 安装耗时未测"，而它已经测出来是 22 秒。

做了一次清理：

1. **ISSUES 的「当前剩余问题」定为唯一待办来源**（README 文档索引里写明了）。P0 关闭后
   从主列表移出，判据压缩成文末的「已关闭记录」，不再占正文位置；
2. **PLAN §10 从 26 项平铺改成三组**：会挡下一步的 4 项、只影响特定场景的 5 项、
   瘦身/排障相关 3 项；已有结论的 13 项收进一张结论表，不再混在待办里；
3. **新增 T11**（UI 手动安装更高版本能否覆盖升级）——这是清理时才意识到的空白：
   CLI 路径早就证明不行（§2.7 / P1），但**界面路径从没验过**，而它决定以后每次升级
   要不要先卸载。判据与命令都写全了，失败也不亏（数据在共享目录）；
4. **PLAN §7 加了前提失效警语**：整节建立在"覆盖安装会触发 upgrade 钩子"上，该假设已证伪，
   不标出来会让后来人按错的地图走；
5. **PLAN §12 只留一条开放问题**：运行时、入口、TLS、保留旧 runtime、备份五项都已定或消失，
   只剩「绑定地址要不要在向导里可选」，且它和 T7 是同一个决定；
6. **PLAN §6.1 数据更新**：866MB/63053 → 包 990MB、装完 957M/63056；磁盘门禁实际 1.5GB
   （文档原写 1.2GB）；并说明瘦身的价值已从「不然装不上」降级为「省盘省传输」。


## 阶段 16：0.6.0 打包通过，顺手挖出构建脚本的路径假设（23:44–23:58）

`bash build.sh full` 在 NAS 上跑通：**通过 58 / 跳过 0 / 失败 0**
（0.5.0 是 56，新增 F17 的双绑 2 条），`dsh 版本校验通过：0.2.1-rc.3`，
`app/` 977M / 63054 文件，产物 **`dsh.fpk` 199MB**。开头的
「沙箱内已移除残留的 dsh 运行时」如预期出现（F14 的隔离生效）。

但日志里有两行不对劲：

```
包：dsh 0.6.0    已安装：<无>
没找到共享目录（应用还没装？），包留在 /root/dsh-fnos/fpk/./dsh.fpk
```

同一时刻应用明明在跑（复测 `3080/healthz` 200、`3080/` 302、`3081/` 401）。
两个检查都只认 `/var/apps/<app>`——那是平台挂的**软链入口**，实测会不在。

后果比「少一句提示」严重：

1. **版本守卫（F12）静默空转**：读不到已装版本 → `INST_VER` 为空 → 同版本也照打，
   装上去是空操作。F12 想拦的正是这个；
2. **包落到 `/root`**：文件管理看不到，界面「手动安装」选不到，等于把「打完就能装」砍掉。

修法（`build.sh`）：已装版本按 `/var/apps` → `/vol1/@appcenter` → `/vol1/@appmeta` 依次找并
打印读自哪里；三处都没有而 `appcenter-cli check` 说已安装时，**明确警告守卫本次无效**；
包落点把头号候选换成 `/vol1/@appshare/<app>/workspace`（卸载保留数据后仍在）；
全找不到时直接打印可复制的 `cp` 命令。三种场景（对齐空格的 manifest / 目录不存在 /
有文件但无 `version`）本地各跑一遍，`set -e` 不会被误触发。

文档同步：RUNBOOK 抬头加「软链 ↔ 实体路径」对照表（`var`→`@appdata`、`etc`→`@appconf`、
代码→`@appcenter`、共享→`@appshare`），第 0/2/3 步与 4.1 的 manifest 读取改成两处都试，
并写明「包落在 /root 时的一行 `cp`」；README / ISSUES 的体积表述拆成
「包内 977MB / fpk 199MB / 装完 957M」，避免再把下载体积当成 990MB。

教训与 F14 同源：**凡是「按某个路径存在与否判断状态」的地方，都要先问它是不是平台/构建
生成的临时物**。F14 是 `.gitignore` 的构建产物，F20 是平台的软链入口。


## 阶段 17：0.6.0 上真机，T10 / T11 双双结案（10-27 23:49 ~ 10-28 00:30）

前端手动安装 0.6.0（**未先卸载**），详情页版本变成 `0.6.0`、来源「手动安装」、状态「运行」。
三条命令一次把两件事判清楚：

```
server.mjs 落盘   2026-10-27 23:49:35.738
launcher 进程启动 2026-10-27 23:49:45          ← 晚 10 秒
loop=200 / lan=200 / status=running
```

**T11 ✅ 覆盖安装可行**。平台在替换 `target/` 之后**自己重启了进程**（以前不知道升级会不会
重启，现在能确认）。以后升级直接装更高版本，不用「卸载保留 → 再装」，`dsh-home` 与共享
目录都不受影响。第 6 项 `upgrade_init` 空输出属正常——我们的钩子是空实现，平台也不记录，
判文件换没换看 mtime、判进程新旧看 lstart，比钩子日志可靠。

**T10 ✅ 是 UI 入口，不是缺陷**。「停用 / 卸载」收在**「打开」右侧那个 `▼`** 里，点开才有。
飞牛管这项操作叫「停用」，按「停止」两个字去找永远找不到。

顺带**证伪了 F17 的推断**：manifest `ctl_stop=true`、`status=running`、回环 `loop=200`、
`ss` 显示同一进程双绑 `127.0.0.1:3080` + `192.168.0.114:3080` —— 四个条件全满足，界面
照旧。所以「平台靠回环探测判断运行状态」这条假设是错的。F17 本身保留（本机自检、以后
接网关都依赖回环可达），但它不再解释按钮问题。

`probe/05` 报 `34 PASS / 2 WARN / 1 FAIL`。FAIL 是「存在两套 workspace」，看着像掉数据
（会话凭空消失），查下来是**断言读错了行**：

```bash
grep -oE 'home=[^ ]+' "$ROOT/var/info.log" | head -n1     # 取的是最早一条历史记录
```

`info.log` 跨版本累积，0.5.0 早期那条指向 `@appdata`，拿它跟当前软链比必然不等。实测三条
反证：进程环境里 `home=` 全指向 `@appshare/dsh/workspace/.dsh-home`；`@appdata/dsh/dsh-home`
与 `@appdata/dsh/workspace` **都不存在**；那个目录属主 `dsh:AppUsers`、权限 700，只有一份。
改成取最后一条，并加「目录真的存在才算分裂」的兜底。

另一个 WARN 是真 bug（F15）：密钥权限 `700` 一直没被收敛。根因是位运算写错——

```
0o700 & 0o077 = 0        → 条件 "!== 0" 恒假 → 从不 chmod
0o644 & 0o077 = 0o044    → 只有这种情况才触发
```

`0o077` 只看 group/other 位，而 700 多出来的 `0o100` 是 owner 执行位，落在掩码外。改成整段
比对 `(mode & 0o777) !== 0o600`，700/600/644/777 四种值逐个验过。


## 阶段 18：0.6.1 —— 两个补丁，一次推送（00:35）

F15 权限位判断 + `probe/05` 取最后一条日志。自测 **32 通过 / 22 跳过 / 0 失败**，
推送 `af3b49b`。

同轮否掉了「T6 绑全地址」的顺手改法：查代码发现 **dsh 本体明确拒绝 `0.0.0.0`**
（启动时直接 `die`，注释里写着实测结论）。这不是加一行参数的事，属拓扑改动，而当时
`.114` 用着完全正常、没有实际故障。原则：**不在一次小修里同时动网络核心**。


## 阶段 19：图标换了四轮，才找到真因（00:40 ~ 01:04）

| 轮次 | 改动 | 结果 |
|---|---|---|
| 0.6.2 | 入口图 64 → 256 像素（文件名不变） | 用户：**还是很糊** |
| 0.6.3 | 深蓝底 + 白鲸剪影，提对比度到 6:1 | 用户：**还是糊的**（但新设计已生效，排除缓存） |
| 0.6.4 | 定位到包根 `ICON.PNG` 是 64，提到 256；底色加深到 `#23328C`（11:1） | 仍不理想 |
| **0.6.5** | **原样用官方 `apps/web/public/icon-512.png`** | 用户：**好很多** ✅ |

中途做过两次有价值的取证：

1. **量社区同款项目**（GitHub API 逐个读 PNG 头）：`ICON.PNG` 分别是 640 / 128 / 64 / 64 / 64，
   两个热门项目干脆让 `ICON.PNG` 与 `ICON_256.PNG` 指向同一个 640×640 文件。→ **64×64
   不是安装器的硬约束**，只有 `fnpack build` 会校验（我们用自研 `build.sh` 打 tar）。
2. **找官方成品图**：仓库里有三套完全不同的资源——`website/public/favicon.svg`（50×50
   站点小标，细线条）、`apps/web/public/icon-512.png`（PWA 图标，浅底 + 深色实体鲸）、
   `apps/desktop/resources/icon.png`（1104，带纸张纹理）。**前四轮一直在拿站点小标当
   应用图标**，这才是根因。

教训三条，按顺序：**先确认素材是不是产品级图形 → 再确认渲染的是哪个文件 → 最后才算
像素与对比度**。只算像素会把对比度问题误判成分辨率问题；只改 `ui/images/` 会漏掉真正
被读取的包根 `ICON.PNG`。


## 阶段 20：0.6.5 定稿（01:04）

四个位置放同一个文件，SHA-256 一致（`0aa6ff8c…`），未缩放、未调色、未重绘。
`build.sh` 校验放宽为「正方形 / 边长 64~1024 / ≤1024KB」，不再硬性要求 64 或 256。
`probe/05` 同时打印**入口图标**与**包根图标**的真实像素，下次装包能直接判定平台读哪张。

用户装完反馈「好很多」，F21 关闭。0.6.0 → 0.6.5 期间累计关闭：T10、T11、F15、F21，
以及 `probe/05` 的 workspace 误报。


## 阶段 21：0.6.6 —— 「没有默认工作区」（2026-10-28 23:20）

用户报「缺少默认工作区」，附截图：工作区下拉里只有他自己建的 `Project` 和
「+ 添加工作区…」，没有内置的「默认工作区」。

**先排除误判**：`storages/workspace.json` 结构正常（`initialized: true`、一条 `Project`、
4 个会话），`.dsh-home` 属主与权限都对，启动日志无异常。所以不是数据目录缺失，
也不是我们封装漏了什么文件。

**逐层定位**（每一层都是真机输出，不是猜）：

1. dsh 是 cordis 插件架构，工作区逻辑在 `@deepseek-ai/dsh-workspace` 与
   `dsh-api-workspace-controller`，不在入口壳 `dsh/lib` 里 —— 前两轮 grep 因此一无所获。
2. `initializeDefault()` 的守卫是「注册表 + 会话历史双空」，我们这台早已非空 →
   **它不会再补建**，这解释了「为什么现在没有」，但解释不了「首启为什么没建」。
3. 继续看 `defaultWorkspaceDirectory()`：linux 下执行 `xdg-user-dir DOCUMENTS`，
   实测该命令输出 `/vol1/@appshare/dsh/workspace/.dsh-home` —— **正好等于 `homedir()`**，
   下一行就 `throw new Error("system Documents directory is unavailable")`。
4. 根因是 `xdg-user-dir` 只读 `$HOME/.config/user-dirs.dirs`，文件不存在时**回显 `$HOME`**；
   而我们的 `HOME` 就是 `.dsh-home`，里面没有 `.config`。开发机 Windows 走
   `powershell.exe` 取 `MyDocuments`，所以从来没暴露过。

**修法两条，一条治本一条治标**（只做前者对已装实例无效，只做后者只救个案）：

- 治本：启动前写 `$HOME/.config/user-dirs.dirs`（`XDG_DOCUMENTS_DIR=<共享目录>`）、
  建好 `<共享目录>/deepseek-harness/default-workspace`、属主交应用用户，并钉住
  `XDG_CONFIG_HOME`。这样 dsh 自己的 `initializeDefault` 就能跑通。
- 治标：新增 `cmd/ensure-default-workspace.mjs`，在 dsh 停止时按 canonical 路径去重合并
  注册表，补一条 `title="default-workspace"` 并写 `defaultWorkspaceId`。只加不改、幂等、
  写前留 `.bak`、结构不认识就不动。

**两个容易写错的地方，记下来**：

1. `title` 必须是英文常量 `default-workspace`。前端拿它比对后才本地化成「默认工作区」，
   直接写中文会变成一条普通工作区。
2. 补登记只能在 dsh 停止时做。注册表是 `dsh-storage-json` 管的版本化存储，dsh 内存里有
   副本，运行中改会被覆盖。`do_start` 里放在 `is_running` 早退之后、`spawn` 之前。

**验证**：`bash fpk/selftest.sh` → **43 通过 / 22 跳过 / 0 失败**（新增 11 条：文档目录取值、
不等于 HOME、目录已建、补登记幂等、原会话未被破坏、新登记排首位）。
真机验证待装 0.6.6，判据写进 ISSUES 的 P2。


## 阶段 22：0.6.7 —— 「访问权限」被我们自己关掉了（2026-10-28 23:30）

用户报：**「添加访问权限，可以添加目录文件夹作为工作区」**，附的是 Gitea 的设置截图
——`访问权限` 页、`允许访问以下文件夹`、`读写` 下拉、`+ 添加`。言下之意：dsh 这儿没有。

**一句话根因**：`fpk/manifest` 里写着 `disable_authorization_path="true"`。

那是 0.4/0.5 的保守选择（当时没打算让 dsh 碰用户文件），但它和 dsh 的定位矛盾：
dsh 是通用工作台，工作区天然是用户的任意目录。这个字段一关，应用设置里**整页隐藏**，
用户连授权入口都没有；而应用用户 `dsh` 对 `/vol1/1000/...` 这类目录没有任何权限位
（通常是 `700`、属主是用户本人），于是加工作区必然 `EACCES`。

**顺手把「开权限够不够」这件事查实了**（避免又改成半截）：

- dsh 的目录选择器是自适应的（`dsh-host-directory-picker-auto`），判定表第一行就是
  「绑定地址不是 loopback → `browse`」。我们的绑定是 `192.168.0.114`，**必定走 browse**。
- 而 `dsh-host-directory-picker-browse` 的 README 明写「**全盘可浏览** —— 没有按部署限定的
  浏览根；`workspace.create` 接受任意路径」，`list()` 从 `homedir()` 起步、带 `/` 面包屑。
- 结论：**权限到位之后，路径不需要我们再映射或暴露**，用户在对话框里自己点过去就行。
  这直接否掉了我原本想做的「往共享目录里造软链」的方案 —— 多余。

**改动**：

| 位置 | 改动 |
|---|---|
| `manifest` | `disable_authorization_path="false"`（并加注释说明为什么不能改回去），版本 → `0.6.7`（0.6.6 的 F22 还没装机，合并到一个包发） |
| `cmd/main` | 新增 `log_accessible_paths()`，在 `do_start` 拉起 dsh 前把 `TRIM_DATA_ACCESSIBLE_PATHS` 逐条写进 `info.log`（`auth-paths:` 前缀，标「读写 / 只读 / 不存在 / 进不去」），只记录不改权限 |
| `fpk/selftest.sh` | 新增 6 条断言（manifest 开关、日志有记录、读写分支、不存在分支、条数统计） |
| `probe/05` | 新增两条验收：安装后的 manifest 是 `false`、日志里有 `auth-paths:` |
| 文档 | ISSUES **F23**（根因 + 两条来源的区别 + 使用路径 + 两个坑）、RUNBOOK **5.3**、`fpk/README`、README、官方底本 §3.5 |

**为什么不顺手把「授权目录自动登记成工作区」也做了**：用户删掉工作区后，我们每次启动
又会加回来，除非再维护一套 tombstone。而 dsh 的删除只删登记、不删文件，用户完全可能是
「暂时不用了」。宁可让用户点两下，也不要制造删不掉的条目。

**验证**：`bash fpk/selftest.sh` → **48 通过 / 22 跳过 / 0 失败**（43 → 48）。
真机判据在 ISSUES P2（F23 那条）。


## 阶段 23（2026-10-28 深夜）　授权目录点不到：选择器从隐藏的家目录起步（F24）

0.6.7 装上后，用户在「访问权限」里把 `存储空间1/T366的文件/Project` 加成「读写」，
然后在 dsh 里「+ 添加工作区」，弹出的「选择工作区目录」只有
`channel-pack / openai-gateway / our-free-model / profiles / Project / sessions / storages`
—— 全是 `.dsh-home` 的内容，授权目录不在里面，也没有上一级可点。

**结论**：F23 打通的是「权限」，这一条断在「导航」。两处源码叠加：

1. `dsh-host-directory-picker-browse` 的 `list(path)`：`path` 缺省时
   `const target = resolve(path ?? home)`，`home = homedir()`。我们的 `HOME` 是
   `.dsh-home`，所以首屏就是这个隐藏数据目录。
2. `dsh-client-ui-directory-picker-browse` 的 `displayCrumbs()`：面包屑里一旦出现
   `listing.home`，就把它**以上**整段丢掉，只留一个「主目录」按钮 —— 往上走的路被 UI 掐断。
   唯一出口是右上角铅笔图标（`browser.editPath`）里手打绝对路径。

我上一轮说「权限到位就能自己点过去」是错的：那句话来自 `browse` 后端的 README
（「全盘可浏览」），确实没有浏览根限制，但**起点**在家目录，而 UI 又不给回头路。

**改动**：

| 位置 | 改动 |
|---|---|
| `cmd/main` | 新增 `link_accessible_paths()`：启动前把每个授权目录软链进 `$HOME/可访问目录/`；只清上一轮软链、跳过包含 `.dsh-home` 的路径（防递归）、合并被外层包含的路径、链接名 = 目录名 |
| `fpk/selftest.sh` | 新增 6 条断言（挂载列表、跳过递归、跳过不存在、目录/权限、软链指向、不建越界链）；测试环境加了一个 `shares/photos` 作为可挂载样本 |
| `probe/05` | 新增一条：`$HOME/可访问目录` 是否存在、软链是否还有效 |
| 文档 | ISSUES **F24**（含「为什么不做自动登记」与 0.6.7 上的绕法）、RUNBOOK **5.4**、`fpk/README`、README（含「别把 HOME 挪出去」）、F23 的步骤 2 纠正 |
| `manifest` | `0.6.8` + changelog |

**几个取舍**：

- **不自动把授权目录登记成工作区**。用户删掉的工作区下次启动又长回来，比多点两下更烦；
  软链是被动入口，不会和用户的删除打架。
- **软链放在 `$HOME/可访问目录/` 而不是家目录根**：家目录根已经有 dsh 自己的 `Project`/
  `sessions`/`storages`，混在一起既容易撞名也让人分不清哪个是应用数据。
- **链接名不加重命名后缀**（第一版加了，理由是怕撞 `Project`）。实际上链接在子目录里，
  撞不到；而 dsh 用「选中路径最后一段」当工作区标题，`Project-2` 会直接显示成工作区名。

**验证**：`bash fpk/selftest.sh` → **51 通过 / 24 跳过 / 0 失败**。Windows 上 `ln -s` 需要特权
（`Operation not permitted`），所以软链本身的断言在那里跳过，但「挑哪些路径」的决策靠日志
照常断言。真机判据在 ISSUES P2（F24 那条）。

### 补记：第一次在 NAS 上打包被自己的断言拦下（00:13）

`bash build.sh` 跑到自测时 `FAIL 授权目录已进入待挂载列表`，**其余 82 项全绿**
（日志里 `access-links: photos -> /…/shares/photos` 明明就在）。

那条断言写的是 `grep -qF "$LINKS/photos"` —— 即匹配 `…/可访问目录/photos` 这段**链接路径**，
而成功分支的日志只打了 `名字 -> 目标`，从来没出现过链接自身的路径。它在 Windows 上能过，
是因为那里 `ln -s` 失败走了 WARN 分支，而 WARN 文案里恰好带着 `$dir/$name`。

**所以是「靠错误分支蒙对」的假阳性**，一上 Linux 就翻。改法不是改断言去迁就日志，而是
把日志拆成两件事各记一行：

- `access-links: 挂载 <名字> -> <目标>` —— 决策：这个目录该出现在首屏。
  与文件系统无关，哪个平台都有。
- 只有建链失败才追加 `WARN: 无法创建软链 …`。

断言随之改成匹配「挂载 photos -> <目标>」。教训写进 ISSUES F24 的约束表：
**别让「该不该做」和「做成了没有」共用一行日志**，否则两边的失败会互相掩盖。


## 阶段 24（2026-10-29 00:30）　日志说「读写」，dsh 一个文件都读不了（F25）

用户把 `/vol1/1000/Project` 加成工作区后，agent 在里面逐个文件报
「无法读取（owner:nobody, mode 0000）」，`.readme.md`、`index.html`、`css/`、`js/` 全军覆没；
而 `auth-paths:` 那行日志写的是「读写」。两条信息对立，等于把排错方向带反了。

**根因在我们自己的探测**：`log_accessible_paths()` 用的是 `[ -r ]` / `[ -w ]`，
而生命周期脚本以 **root** 运行。root 有 `CAP_DAC_OVERRIDE`，绕开 mode 位 ——
`0000` 的文件在 root 眼里照样「可读可写」。真正跑 dsh 的是 `dsh` 用户，同一批文件是 `EACCES`。

这是这几天第三次同型错误（前两次：F24 的日志断言靠 WARN 分支蒙对、F22 的
`xdg-user-dir` 回显 HOME 被误当合法值）。**共同点都是「用错的视角去看，得到了一个看起来正常的结论」。**

**改动**：

| 位置 | 改动 |
|---|---|
| `cmd/main` | 新增 `probe_as_app()`：root 时用 `runuser -u` / `su -s` 切到应用用户再 `test`；两者都没有才退回自身身份并留 WARN |
| `cmd/main` | 新增 `sample_unreadable()`：目录可进时抽查前 6 项，统计 dsh 读不了的比例 + 首个样本（属主:组 权限） |
| `cmd/main` | `log_accessible_paths()` 多一条分支：「目录可进，但抽查 N 项里有 M 项 dsh 读不了，如 README.md（nobody:nogroup 0000）」 |
| `fpk/selftest.sh` | 新增断言：以 `nobody` 读 0700-root 的文件必须判为不可读（Linux + root 才跑，Windows 跳过） |
| `probe/05` | 日志出现「进不去 / 读不了」直接 WARN，并指向修复动作 |
| 文档 | ISSUES **F25**、RUNBOOK **5.5**、`manifest` changelog |

**没做的事**：不在启动时 `chown -R` 那批文件。理由有三：那是用户数据不是我们的；
`chown/chmod` 会覆盖 FNOS 的 ACL（F23 已经踩过一次「ACL 与 mode 位不是一回事」）；
应用该做的是把问题**说清楚**，而不是替用户改数据。

**还没定论的**：那批文件为什么是 `nobody:nogroup 0000`。属主不是 `dsh`，说明**不是 dsh 写的**
（dsh 以 dsh 身份写，属主会是 dsh），大概率是从别处拷进来时带的 UID，或某个容器以未映射
UID 写入。这条要等用户跑 `getfacl` + `find -printf '%U:%G %m'` 才能定性，别猜。

**验证**：`bash fpk/selftest.sh` → **51 通过 / 25 跳过 / 0 失败**（Windows 上多出一条跳过）。


## 下一步

**待办不再在这里维护**——统一见 [ISSUES.md](ISSUES.md) 的「当前剩余问题（P0–P3）」。
DEVLOG 只记已经发生的事，避免两处列表各说一套。

当前动作只有一件：

> **在 NAS 上打 0.6.8 并覆盖安装** —— `cd ~/dsh-fnos && git pull && cd fpk && bash build.sh full`，
> 然后应用中心「手动安装」选新包（覆盖升级不用卸载）。装完看四件事：
> 「选择工作区目录」首屏是否有 **「可访问目录」**、里面能否点到刚授权的文件夹、
> 建出来的工作区路径是不是真实路径（RUNBOOK 5.4）、`auth-paths:` 是否如实标出
> 「读不了」而不是继续写「读写」（RUNBOOK 5.5）。顺带确认默认工作区仍在（RUNBOOK 5.2）。


## 阶段 25（2026-10-29）　Web 端附件上传全灭：卷目录 000 撞上 dsh 的 fsync-to-root（F26）

用户在 dsh Web 里附 PDF 一直「上传失败，点击重试」。全程未上 NAS 定位：

1. 本地拉同版本 `@deepseek-ai/dsh@0.2.1-rc.3` 全依赖树读代码——上传对通用文件
   无大小/类型限制，「文件不合规」全部排除；浏览器 Blob Worker XHR →
   `POST /api/session/uploadFileBinary` → `saveFileStreamVerbatim()` 落盘。
2. 开发机经 launcher 302 拿令牌换 cookie，curl 直打真实会话端到端复现：
   小文件与 1.7MB PDF 同回 `gateway/internal` + 底层 `EACCES`。DevTools 的
   「连接中断」是 Worker 传完即销毁、事后取不到响应体的假象。
3. 真机取证逐层排：共享目录根 `000 root:root`（chown dsh:dsh 修复）→ 错误上移到
   `/vol1/@appshare` → 发现 `/vol1`、`@appshare` 也是 000（同日系统重置/更新所致，
   `@appcenter/@appdata/@appconf` 均为出厂 755）。
4. 读了 `dsh-attachment-local` 才定性：落盘前要把 DSH_HOME 每层祖先
   `open(O_RDONLY)+fsync` 到文件系统根，飞牛卷目录 000（无 r 位）必杀这条链。

修复 `chown dsh:dsh /vol1/@appshare/dsh` + `chmod o+rx /vol1 /vol1/@appshare`，无需重启。
验收：同会话 curl 传 10B 与 1.7MB PDF 均 `{"ok":true}`，PDF 68ms。详见 ISSUES F26。

**升级注意**：任何把 `/vol1`/`@appshare` 改回 000 的平台行为都会让附件再次全灭。


## 阶段 26（2026-10-30 21:45）　「添加插件」全灭：dsh 只转发给 pnpm，而包里没有 pnpm（F28）

用户在 Web 界面添加插件（包名 `billion-context`）报：

```console
无法获取插件信息: Command failed with ENOENT: pnpm view billion-context name version
description dsh --json --registry=https://registry.npmmirror.com/ --config.fetch-retries=0
spawn pnpm ENOENT
```

**先排除的三个方向**（都没花打包时间，纯查证）：

| 怀疑 | 查法 | 结论 |
|---|---|---|
| 包名写错 / 包不存在 | `curl registry.npmmirror.com/billion-context` | 存在，latest `0.1.209` |
| dsh 版本太老没有插件功能 | 截图里有完整「添加插件」表单 | 功能在，是执行层失败 |
| 网络 / 镜像不可达 | 报错是 ENOENT 不是 ETIMEDOUT | 根本没发起请求 |

**根因**在本机源码里就能定位：`dsh` 的 `lib/plugin-*.js` 把插件操作**原样转发给 pnpm**
（`runPluginCommand` / `runProfilePnpm`），且失败分支专门写了
`exitCode === 127 → "pnpm was not found; install pnpm and make it available on PATH"`。
而我们的 `build.sh` 只 `cp "$NODE_SRC/bin/node"`，注释还写着「npm/npx 是软链，运行 dsh 用不到」。
那句话在「插件」这个功能出现之前是对的。

**改动**：

| 位置 | 改动 |
|---|---|
| `build.sh` | full 模式 `npm install --prefix app/runtime/pnpm pnpm@10.34.9`；在 `app/runtime/node/bin/pnpm` 生成 sh wrapper；打包前 `pnpm --version` 自检，不符即 `die` |
| `cmd/main` | 启动时 wrapper 存在则 `export PATH="$RUNTIME/node/bin:$PATH"`，日志记 `start: pnpm=… version=…`；缺失只 WARN，不阻断 |
| `selftest.sh` | 造一个「假 pnpm」验证前置链：断言日志里的路径与版本来自包元数据；Linux 上读 `/proc/<pid>/environ` 确认 PATH 真进了子进程 |
| `manifest` | `0.6.9` + changelog 前置一段（0.6.9 的根因、版本理由、插件落点） |
| 文档 | ISSUES **F28** + 总表补 F26/F27/F28；本段 |

**两个版本判断**：

- **钉 pnpm 10.34.9，不追 latest 12.x**：dsh 的引导文案让用户改
  `pnpm-workspace.yaml` 的 `allowBuilds`；查官方文档，这个字段 10.26 才引入，v11 起成为
  唯一写法（`onlyBuiltDependencies` / `neverBuiltDependencies` 被移除）。10.34.9 是 10.x
  最新维护版，engines `node>=18.12`；12.x 发布才两个月，没有必须冒的风险。
- **wrapper 而非软链**：pnpm 的 shebang 是 `#!/usr/bin/env node`，会命中系统 PATH 的 v22.19
  ——这正是 `cmd/main` 头部第 4 条设计要点记着的坑。wrapper 里 `exec "$here/node"`，
  pnpm 与 dsh 用同一个 v24，`process.execPath` 也就不会指向别的 node。

**验证**：`bash fpk/selftest.sh` → **53 通过 / 26 跳过 / 0 失败**（原 51/25）。
第一次跑挂在「pnpm 版本取自包元数据（实际 未知）」：我用 `sed` 按**行首**匹配 `"version"`，
而测试造的 package.json 是单行。改成用 node 解析 JSON —— 真实 pnpm 的 package.json 虽是多行，
但「依赖 JSON 排版」本身就是个不该留的假设（F24 的教训：别让判据依赖偶然成立的格式）。

**没验的**：真机装 0.6.9 后 pnpm 能否真的 `add` 成功（store、registry、磁盘都在 NAS 上）。
判据写在 ISSUES P2 的 F28 那行。

### 26.1　NAS 第一次 full 构建：自检抓出 wrapper 少写一级

```console
安装 pnpm@10.34.9 ...
ERROR: pnpm wrapper 无法运行：Error: Cannot find module
'/root/dsh-fnos/fpk/app/runtime/node/pnpm/node_modules/pnpm/bin/pnpm.cjs'
```

`$here` 已经是 `runtime/node/bin`，我写成 `../pnpm`（落到 `runtime/node/pnpm`），应为
`../../pnpm`。**值得记的不是这个算术，而是它为什么没在本地暴露**：本地自测里的「假 pnpm」
只 `printf` 一个版本号，从不碰 `pnpm.cjs`；`build.sh` 里那条 `pnpm --version` 是第一次
真的执行这个 wrapper 的地方 —— 也就是说，唯一的守门人来自我 20 分钟前刚写的自检。

三处加固：

1. wrapper 自带守卫：`pnpm.cjs` 不存在就输出完整路径 + `exit 127`，而不是让 node 抛
   `MODULE_NOT_FOUND` 的栈（那条栈的第一行看上去像 dsh 的 bug，不像打包问题）。
2. `build.sh` 的自检改成 `cd /` 再调用：在 `fpk/` 里调用时相对路径恰好也能解析对，
   只有换 cwd 才能证明它找的是自己旁边的文件。
3. `selftest.sh` 新增两条断言：把 build.sh 的 heredoc 原样抽成模板（并断言「抽到了」，
   因为 awk 模式对不上时会安静输出空文件然后「通过」），按 `runtime/node/bin` +
   `runtime/pnpm` 的真实布局在沙箱跑一遍，用 shim 顶替 node。

**反向验证**：把 `../../pnpm` 改回 `../pnpm` 再跑自测 → `通过 54 / 跳过 26 / 失败 1`，
失败信息直接打印出错的绝对路径；改回后 `55 / 26 / 0`。这一步不能省 —— 一条从没红过的
断言，和没有断言是一回事（F24 同类问题）。


## 阶段 27（2026-11-01 16:45）　pnpm 干活还得靠 npm，而包里没有 npm（F29）

0.6.9 装上真机后 `spawn pnpm ENOENT` 消失了，报错换成：

```console
无法获取插件信息: npm error Class extends value undefined is not a constructor or null
npm error   /vol1/@appshare/dsh/workspace/.dsh-home/.npm/_logs/2026-11-01T08_28_11_411Z-debug-0.log
```

**怎么一步步锁定的**（每步排掉一个方向，剩最后一个就是答案）：

1. 本地用同版本 pnpm 10.34.9 跑完全相同的命令 → 正常返回 JSON。pnpm 没坏。
2. 读 npm 调试日志 `verbose cli` → `…/runtime/node/bin/node /usr/local/bin/npm`。
   被执行的程序是**系统 npm**，参数与 dsh 发的一模一样。
3. 在 pnpm wrapper 里加一行日志 → `argv0=…/runtime/node/bin/pnpm args=view …`。
   我们的 pnpm **确实跑了**，PATH 前置有效（这一步是分水岭：排除「PATH 没传进去」）。
4. profile 的 `package.json`、`.npmrc`、`cordis.patch.yml` 里都没有 `packageManager` /
   `npmCommand`。不是配置改的。
5. pnpm 源码 `run-npm/lib/index.js`：`const npm = npmPath ?? "npm"` —— `view` / `config`
   这些子命令 pnpm 自己没实现，**直接 spawn 裸命令 npm 转发**。

合成一句话：`runtime/node/bin` 里只有 `node` 和 `pnpm`，pnpm 转发时按 PATH 找到系统
`/usr/local/bin/npm`（10.9.3），而 wrapper 用自带 node 24 去跑它 —— npm 10.9 与 node 24
不兼容，崩在 `minizlib` 的 `Class extends value undefined`。

### 27.1　修法与那条「必须真跑一次」的自检

| 位置 | 改动 |
|---|---|
| `build.sh` | 装 `npm@11.21.1` 到 `app/runtime/npm`，生成同构 wrapper `node/bin/npm`；两条版本自检 + **端到端自检** |
| `cmd/main` | 日志加 `start: npm=… version=…`；缺了 WARN |
| `selftest.sh` | 假 npm + npm wrapper 模板按真实布局跑；日志断言拆成 pnpm / npm 两条 |
| `probe/05` | 缺 npm 直接 FAIL |

端到端自检就是用户点的那一下，去掉「界面」只有命令：

```bash
cd /tmp && PATH="<runtime>/node/bin:$PATH" pnpm view lodash version \
  --registry=https://registry.npmmirror.com/ --config.fetch-retries=0
```

输出必须是版本号（已确认 npm 10/11 都认 `--config.fetch-retries=0` 这种写法，
本地 `npm view lodash version --config.fetch-retries=0` 返回 `4.18.1`）。无外网时
`DSH_SKIP_NETCHECK=1` 可跳过，但那等于自废这层保障。

**为什么必须是端到端**：前两条自检（pnpm 能跑、npm 能跑）在 0.6.9 上**都是绿的**，
坏的恰恰是两者之间的转发。判据只有「失败的那条命令本身」才算数。

### 27.2　顺手修的抽取逻辑

`selftest.sh` 里从 build.sh 抽 wrapper 模板的 awk 原本在每个块尾把 `f=0` 继续扫文件；
现在有了第二个同样的 `<<'WRAP'` 块，第二段会被**追加进第一个 wrapper**（`exec` 在前，
追加的部分不执行，所以不会报错，只会静默污染）。改成取到第一个 `^WRAP$` 就 `exit`，
并把 `index($0, pat) == 1` 改成 `> 0` —— build.sh 里这行有缩进，`== 1` 一条都抽不到
（第一版就是这么红的：`通过 51 / 失败 8`）。

自测最终 `通过 59 / 跳过 26 / 失败 0`（比上一轮 +4：npm 两条、pnpm 一条拆分、多一条模板。
真机 Linux 上「跳过 0」）。

**没验的**：真机 0.7.0 上 `pnpm add` 能否真的装完（store、registry、磁盘都在 NAS 上）。
判据在 ISSUES P2 的 F29 那行。

### 27.3　端到端自检第一次红：判据太窄，把成功的构建拦下了

真机 0.7.0 构建跑到端到端那步：

```console
端到端自检：pnpm view lodash version（会真的走 pnpm → npm 转发）...
ERROR: pnpm view 走不通（pnpm 会把 view 转发给 npm，两者必须成套）：
npm warn Unknown cli config "--config.fetch-retries". This will stop working in the next major version of npm.
4.18.1
```

**命令是成功的**——`4.18.1` 就在最后一行。我原来的判据是 `case "$VIEW_GOT" in [0-9]*.[0-9]*)`，
要求整段输出以数字开头；npm 11 往 stderr 打了一行 warn，合并回来（`2>&1`）后第一行就不是数字了，
于是「成功」被读成「失败」。

修法：**取最后一行像版本号的**，而不是要求整段就是版本号。

```sh
VIEW_VER="$(printf '%s\n' "$VIEW_GOT" | grep -E '^[0-9]+(\.[0-9]+)+$' | tail -n1 || true)"
```

两个细节：

- `|| true` 不能省。build.sh 是 `set -euo pipefail`，一条都没匹配上时管道非零，会让脚本
  在「没有版本号」这个**正确分支**上静默退出，而不是走到 `die` 打印原因。
- 用**整行锚定**（`^…$`）而不是「包含数字」：报错文本里可能带 `/usr/local/bin/npm 10.9.3`
  这类片段，宽松匹配会把失败读成成功——那才是最坏的方向。

四种输入都验过：`warn + 4.18.1` → `4.18.1`；只有 `npm error …` → 空（→ die）；
纯 `4.18.1` → `4.18.1`；`0.9.26` → `0.9.26`。

### 27.4　意外收获：npm 12 会废掉 dsh 传的那个参数

那行 warn 不是噪音，是结论：

```
npm warn Unknown cli config "--config.fetch-retries". This will stop working in the next major version of npm.
```

dsh 查包时固定传 `--config.fetch-retries=0`（控制重试次数），npm 12 起这个写法不再被识别。
所以钉 npm 11.21.1 不再只是「追新有风险」的判断，而是硬约束：**11 是同时满足
「node 24 兼容」与「认 dsh 参数」的最后一版**。以后要升，先确认 npm 认不认这个参数。

（顺带：pnpm 10.34.9 对同一个参数默默接受，所以真正挑版本的是 npm。）

## 阶段 28（2026-11-01 17:05）　运行时跟到 dsh 0.2.1-rc.5（包 0.7.1）

rc.3 是 10-23 的版本，npm 上已经到 rc.5（10-29 发布，GitHub 10-30 的 release）。

### 28.1　先确认「升上去会变什么」

升级前做了三项核对，都是可查的事实，不是「新版本应该更好」：

| 核对项 | 结果 |
|---|---|
| 依赖集 | rc.3 与 rc.5 **完全相同**：86 个包，逐个只把版本号从 rc.3 换成 rc.5，没有新增、没有删除、没有范围变化 |
| 引擎要求 | 两者都没有 `engines` 字段，node 侧没有新门槛（我们带的是 v24.22.1） |
| 改动内容 | rc.4 是「无变更重发」（rc.3 与 rc.4 的五个子包逐字节相同，只有版本号不同）；rc.5 是**对话里思考内容的展示优化**，纯前端 |

也就是说，这次升级不会碰原生件、不会改解包体积假设、不会动 fpk 的架构判定 —— 属于
「换一个前端 bundle」的量级。这也正是先升 rc.5、暂不动 `0.2.2-alpha.*` 的原因：alpha 线在改
插件管理（富文本详情、第三方插件更新、热更新回滚），跟我们刚修完的 F28/F29 同域，
等它转 rc 再跟，避免一次动两个变量。

### 28.2　改了什么

| 位置 | 改动 |
|---|---|
| `fpk/build.sh` | `DSH_VERSION` 默认 `0.2.1-rc.3` → `0.2.1-rc.5`，并把「为什么钉版本」「为什么是 rc.5」写进注释 |
| `fpk/manifest` | 0.7.0 → **0.7.1**，changelog 前插一条 |
| `probe/02-smoke-dsh.sh`、`probe/README.md` | 探针的默认 `PKG` 同步到 rc.5（不跟的话探针测的是一个和包里不同的 dsh） |
| `PLAN.md` §3.2 | 版本表与结论重写，补上「升级时先核对依赖集与插件接口」 |
| `docs/RUNBOOK.md` | 打包判据里的版本号、体积（pnpm 23M / npm 20M 实测）与产物版本 |
| `README.md`、`fpk/README.md` | 运行时版本与包版本 |

`build.sh` 的版本校验没动：它回读装进来的 `package.json`，与 `DSH_VERSION` 不相等就中止。
所以「装到 rc.3 却打出 0.7.1 的包」这种事故不会发生 —— 这也是为什么改一个字符串就够，
不需要额外的守卫。

### 28.3　顺带记下的一个隐患

dsh 升级会连带换掉 `cordis.patch.yml` 那套插件接口的实现。`plugin-web-search-ddg/` 是照着
rc.3 的 `registerSearchProvider` 写的、**从未真机验证过**（一直 WIP）。0.7.1 装上后如果插件
能装进 profile 但加载时报接口不存在，先查这条，别去翻 pnpm。

判据记在 ISSUES P2 的「dsh 升到 rc.5」那行：版本校验行、首屏与旧会话、以及 F24 的
「可访问目录」入口是否还在（前端改版可能动到路径）。
