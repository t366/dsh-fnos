# REF：dsh 联网搜索插件接口情报（来自会话导出 session-12bf13b0）

> 来源：`dsh-session-session-12bf13b0-7e28-464e-8a9a-746f6480af51.zip`
> 该会话里 dsh 内置 AI 实地读取了 NAS 运行时（`/vol1/@appcenter/dsh/runtime/app`），
> 本文记录它摸清的接口。插件实现在 `plugin-web-search-ddg/`。

## 1. Web 能力接缝（`ctx.web`，包 `@deepseek-ai/dsh-web`）

搜索与抓取共用一个接缝，注册方式：

```ts
// dsh-web/lib/types/index.d.ts L70
registerSearchProvider(provider: WebSearchProvider): () => void;  // 返回注销函数
registerFetchProvider(provider: WebFetchProvider): () => void;
```

### 核心类型（`dsh-web/lib/types/types.d.ts`）

```ts
interface WebSearchRequest {
  readonly query: string;
  readonly maxResults?: number;   // 接缝层会强制截断
}

interface WebSearchResult {
  readonly content?: string;               // 可选的生成式摘要
  readonly sources: readonly WebSearchSource[];
  readonly truncated: boolean;             // 由接缝设置，provider 恒 false
}

interface WebSearchSource {
  readonly url: string;          // 必有
  readonly title?: string;       // 可选，UI 用 title ?? hostname(url)
  readonly snippet?: string;
  readonly publishedAt?: string; // ISO-8601
}

interface WebSearchProvider {
  readonly id: string;           // 接缝内唯一
  available(): boolean;          // 便宜的本地检查，禁止网络调用
  search(request, signal?): Promise<WebSearchResult>;
}

class WebError extends HarnessError {}   // 构造：new WebError(message, code, { cause })
```

## 2. Host 插件结构（官方技能 `cordis-plugin-development`）

**Manifest**（Host-only bundle 无需依赖/构建）：

```json
{
  "name": "@local/my-plugin",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "exports": { ".": "./index.js", "./locale/*.json": "./locale/*.json", "./icon": "./icon.svg" },
  "files": ["index.js", "cordis.patch.yml", "locale/*.json", "icon.svg"],
  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
}
```

**cordis.patch.yml**：

```yaml
- insert:
    - id: my-plugin
      name: '@local/my-plugin'
      config: {}
```

**index.js 导出形式**（二选一，不混用）：

```js
export const inject = ['web'];
export const Config = z.object({ ... });   // 可选，schemastery（@deepseek-ai/schemastery）
export function apply(ctx, config) {
  const unregister = ctx.web.registerSearchProvider(provider);
  return unregister;   // 返回清理函数
}
```

**展示元数据**：`locale/<lang>.json` 里 `meta.title` / `meta.description`；
图标 SVG/PNG/JPEG/WebP ≤256KiB，必须在包内（绝对路径/URL/符号链接会被拒）。
`Config` 的字符串字段用 `.role("secret")` / `.role("credential-ref")`，动态项加 `.volatile()`（参考 deepseek 插件写法）。

**安装**：用 `plugin_manager` 的 `install_bundle`（dsh agent 的工具），不要用 shell 复现安装。
新 bundle 可经 HMR 激活；替换已装包需要重启。

## 3. 官方参考实现（`dsh-web-search-deepseek/lib/index.js`，342 行）

结构模板：

```js
const name = "web-search-deepseek";   // cordis 插件名
const inject = ["web"];
const Config = z.object({ apiKey: z.string().role("secret").volatile(), ... });
function resolveOptions(ctx, config) { ... }        // 每次搜索快照一次配置
function apply(ctx, config) {
  ctx.web.registerSearchProvider(new DeepSeekSearchProvider(() => resolveOptions(ctx, {...})));
}
export { Config, apply, inject, name };
```

要点：
- Provider 构造参数是 **thunk**（`() => options`），每次 search 入口快照，避免配置变更时重注册造成 UI 闪烁
- 错误码惯例：`WEB_ABORTED`（取消）、`WEB_PROVIDER_ERROR`（provider 失败）；重定向失败算错误
- 取消：包装 `AbortError` 为 `WEB_ABORTED`，保留 `signal.reason`

## 4. 会话里的环境发现（踩坑记录）

- `/vol1/1000/Project` 属主 `nobody:nogroup`，dsh 用户（uid 971）**不可写**——agent 的 mkdir 被拒
- `/vol1/@appshare/dsh/workspace` 可写（首次 mkdir 报 Read-only 是沙箱误报，经 escalation 后成功）
- dsh agent 写的 package.json 第一版有重复 `exports` 键，第二版修正
- dsh 内置两个搜索 provider：`deepseek-official`（Anthropic Messages + web_search 工具）和
  `dsh-web-deepseek-api` 里的 DeepSeekSearchApiProvider；我们的 DDG provider id 用 `ddg-lite` 避开冲突
