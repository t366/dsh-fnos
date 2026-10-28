#!/usr/bin/env node
// ============================================================================
// ensure-default-workspace.mjs — 给「注册表已非空」的实例补一条默认工作区
//
// 为什么需要它（docs/ISSUES.md F22）：
//   dsh 的 workspaceRegistry.initializeDefault() 只在
//   「workspaceIds 空 + archivedSessionIds 空 + 无会话头」时才创建默认工作区，
//   一旦错过就永不再来（删掉登记也不会重新创建）。老用户升级时注册表必然非空，
//   只能由封装层补一次。
//
// 设计约束：
//   · 只加不改：不删任何条目，不动已有 title / sessionIds / 归档状态；
//   · 幂等：已有 defaultWorkspaceId 就直接退出，重复跑不会产生第二条；
//   · 必须停机调用：dsh 在内存里持有这份状态，运行中改会被它覆盖；
//   · 解析不了的结构一律不碰（宁可没有默认工作区，也不能弄坏会话索引）。
//
// 用法：
//   node ensure-default-workspace.mjs --registry <workspace.json> --dir <默认工作区目录>
//
// 输出（单行，供调用方写日志）：
//   created <id>            新建并设为默认
//   defaulted <id>          目录已有登记，仅补 defaultWorkspaceId
//   skip: <原因>            未改动
// 退出码恒为 0：它是启动流程的一步，失败不该拦住应用启动。
// ============================================================================

import { readFileSync, writeFileSync, renameSync, realpathSync, statSync, copyFileSync, unlinkSync } from "node:fs";
import { randomUUID } from "node:crypto";

// dsh 的固定目录名常量（dsh-api-workspace-controller: DEFAULT_WORKSPACE_DIRECTORY）。
// 前端拿它跟 title 比对后本地化成「默认工作区」，所以这里必须原样用英文。
const DEFAULT_TITLE = "default-workspace";

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function done(msg) {
  process.stdout.write(`${msg}\n`);
  process.exit(0);
}

const registry = arg("registry");
const dir = arg("dir");
if (!registry || !dir) done("skip: 缺少 --registry / --dir");

let raw;
try {
  raw = JSON.parse(readFileSync(registry, "utf8"));
} catch (error) {
  done(`skip: 注册表读不出来（${error.message}）`);
}

const globalState = raw && typeof raw === "object" ? raw.global : undefined;
const tables = raw && typeof raw === "object" ? raw.tables : undefined;
if (!globalState || !tables || !tables.workspaces || typeof tables.workspaces !== "object") {
  done("skip: 注册表结构不认识（不是 dsh 的 workspace 存储）");
}

if (globalState.defaultWorkspaceId !== undefined) {
  done(`skip: 已有默认工作区 ${globalState.defaultWorkspaceId}`);
}

// 目录必须真的存在且是目录：dsh 的 realpath 对不存在的路径会抛 ENOENT，
// 我们这一步要是把不存在的路径写进注册表，前端点它就会报错。
let canonical;
try {
  canonical = realpathSync(dir);
  if (!statSync(canonical).isDirectory()) done(`skip: ${dir} 不是目录`);
} catch (error) {
  done(`skip: 目录不可用 ${dir}（${error.code || error.message}）`);
}

const ids = Array.isArray(globalState.workspaceIds) ? globalState.workspaceIds : [];

// 目录已经登记过（用户自己加过）→ 只补 defaultWorkspaceId，不新建
const existing = ids.find((id) => tables.workspaces[id] && tables.workspaces[id].path === canonical);

let next;
let message;
if (existing) {
  next = { ...raw, global: { ...globalState, defaultWorkspaceId: existing } };
  message = `defaulted ${existing}`;
} else {
  const id = randomUUID();
  const now = new Date().toISOString();
  next = {
    ...raw,
    global: {
      ...globalState,
      initialized: true,
      defaultWorkspaceId: id,
      // 与 createCanonical 一致：新登记的排在首位
      workspaceIds: [id, ...ids],
    },
    tables: {
      ...tables,
      workspaces: {
        ...tables.workspaces,
        [id]: { path: canonical, title: DEFAULT_TITLE, sessionIds: [], createdAt: now, updatedAt: now },
      },
    },
  };
  message = `created ${id}`;
}

// 先备份再原子替换：dsh 下次启动读到的要么是旧文件，要么是完整的新文件
try {
  copyFileSync(registry, `${registry}.bak`);
} catch {
  /* 备份失败不阻断：rename 本身是原子的，最坏只是没有回滚副本 */
}

const tmp = `${registry}.tmp-${process.pid}`;
try {
  writeFileSync(tmp, `${JSON.stringify(next, null, 1)}\n`, { mode: 0o600 });
  renameSync(tmp, registry);
} catch (error) {
  try {
    unlinkSync(tmp);
  } catch {
    /* 清不掉临时文件也无所谓，dsh 不认 *.tmp-* */
  }
  done(`skip: 写入失败（${error.message}）`);
}

done(`${message} path=${canonical}`);
