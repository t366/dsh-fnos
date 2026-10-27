# 上真机 runbook —— 打包 → 卸载保留 → 手动安装 → 验收

给 0.5.0 这一版写的执行清单，之后每个版本都可以照抄（把版本号换掉）。

**三条硬规则，先看再动手**

1. **全部命令必须在 NAS 上跑**。`fnpack` 只装在那台机器，`full` 模式要现场 `npm install`，
   Windows 上打不了包。
2. **先下载新包，再卸载旧应用**。卸载流程会把共享目录临时改成 `000`，顺序反了就拿不到包。
3. **只用普通用户**，不要 root。应用本身是 `run-as: package`（专用用户 `dsh`）。

SSH 没开的话：飞牛 → 系统设置 → 终端与 SSH。

---

## 第 0 步　确认已装版本（决定要不要改版本号）

```bash
grep -E '^[[:space:]]*version' /var/apps/dsh/manifest
```

| 输出 | 怎么做 |
|---|---|
| `0.5.0`（与 `fpk/manifest` 相同） | 先把 `fpk/manifest` 的 `version` 提到 `0.5.1` 再打包，否则 `build.sh` 会直接 `die`（F12 版本守卫） |
| 其他（`0.2.0` / `0.4.0` …） | 直接进第 1 步 |

> 为什么必须管：`appcenter-cli install-fpk` 对已装应用只回一句 `is installed`，
> 同版本装上去 `target/` 不会更新。**2026-10-27 之前这条只打警告**，看起来像装成功了。

---

## 第 1 步　拉代码（确认拿到本轮修复）

```bash
cd ~/dsh-fnos
git pull
git log --oneline -1
```

期望最后一行是：

```
72f080b 修复 auto 模式经反代后公网免令牌进入，并补四项健壮性
```

不是这条就先别打包——`build.sh` 打的是工作区里的代码，不是远端。

---

## 第 2 步　打包（5–15 分钟，产物约 990MB）

```bash
cd ~/dsh-fnos/fpk
bash build.sh full 2>&1 | tee ~/build-$(grep -E '^version' manifest | cut -d'"' -f2).log
```

`build.sh` 会先跑 `selftest.sh`（约 30 秒），自测不过直接中止。

**必须看到这三行，缺一行就是没过：**

```
通过 58 / 跳过 0 / 失败 0
dsh 版本校验通过：0.2.1-rc.3
产物：./dsh.fpk（…）
```

- Linux 上「跳过」必须是 **0**。开发机（Windows）上的 22 项跳过是权限位、`/proc`、
  进程组这些只能在真机判定的断言，这里会真正执行，所以通过数会比 30 多。
- 如果自测开头出现「沙箱内已移除残留的 dsh 运行时」，说明源码树里带着上一次 full
  构建的 `app/runtime/app`（`.gitignore` 的，`git pull` 不会清）。这行是**正常且预期**的
  ——自测已经把它隔离在沙箱外，不影响结论。
- 自测失败时看它列出的「失败项」；确认与本次改动无关才用 `DSH_SKIP_SELFTEST=1` 跳过，
  不要因为想快点过而跳过。
- npm 装不上时先看 `/tmp/dsh-npm-install.log`，再确认 registry 能不能连外网。

---

## 第 3 步　先把包下载到电脑（**必须在卸载前**）

飞牛 → 文件管理 → 共享目录 `dsh / workspace` → 下载 `dsh.fpk`。

`build.sh` 打完会自动把包复制到这里；找不到就看第 2 步输出的最后几行，
它一定打印了「包留在 / 已放到共享目录：…」的真实路径。

---

## 第 4 步　卸载（选保留）→ 手动安装

1. 应用中心 → dsh → **卸载** → 弹窗选「**保留会话、凭据与设置**」；
2. 应用中心 → **手动安装** → 选刚下载的 `dsh.fpk` → 安装；
   - 向导里 **API Key 留空 = 沿用旧值**，不要为了"干净"重填；
   - 「入口方式」保持默认「点图标直接进入」；
3. 装完点桌面图标，应当直接进 dsh，不出现配对页。

---

## 第 5 步　验收：结构与入口（只读，不改任何东西）

```bash
bash ~/dsh-fnos/probe/05-verify-fpk.sh 2>&1 | tee ~/p05.log

# healthz 要走绑定地址：127.0.0.1 不通（launcher 绑的是局域网 IP），
# 用回环 curl 只会得到空响应，看起来像没起来。
BIND=$(sed -n 's/^DSH_BIND=//p' /var/apps/dsh/etc/settings.conf | head -n1)
case "$BIND" in ''|auto) BIND=$(sed -n 's/.*bind=\([0-9.]*\).*/\1/p' /var/apps/dsh/var/info.log | tail -n1) ;; esac
curl -s "http://${BIND:-127.0.0.1}:3080/healthz"; echo

# 体积/文件数：/var/apps/dsh 是外壳，target/var/etc 都是软链，du 不跟随。
du -sh /vol1/@appcenter/dsh; find /vol1/@appcenter/dsh -type f | wc -l
```

判据：

- 末尾 `FAIL` 必须为 **0**（`WARN` 允许存在，逐条看是不是已知的那几项）；
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

完整条目见 [ISSUES.md](ISSUES.md)，安装/升级界面步骤见 [../fpk/README.md](../fpk/README.md)。
