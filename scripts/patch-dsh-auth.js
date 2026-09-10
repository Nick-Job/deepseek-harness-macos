#!/usr/bin/env node
/*
 * patch-dsh-auth.js — 关掉 dsh web 的"浏览器信任认证"，让 Pake 壳能直连。
 *
 * 背景：dsh web 从 0.1.2-rc.1 起给每个进程生成一次性 token，只有打开它打印的
 * 带 ?token= 的 URL 才会种下签名 cookie，否则首页与 /api 一律 401
 * "dsh web authentication required; reopen the URL printed by dsh web"。
 * 而 Pake 壳的窗口地址是编译期写死的 http://127.0.0.1:3080，直连必然 401。
 *
 * 对"本机、双击即用"的桌面封装，这里把 BrowserAuth 的两个判定改成恒真：
 *   isAuthenticated()   -> true（Host 侧的 /api 与 WebSocket 放行）
 *   authorizeIndex()    -> true（首页放行）
 * Host/Origin 信任围栏（isTrustedApiRequest）保持原样，仍只接受本机访问。
 *
 * 为什么改方法体而不是调用点：调用点（HostConnectionService.requestRejection
 * 等）在版本间更容易改名/内联，而 BrowserAuth 的这两个方法名是它的语义出口，
 * 跨版本稳定得多。写入的补丁标记同时用于幂等判断。
 *
 * 用法: node patch-dsh-auth.js <运行时目录 | dsh 包目录>
 */

import { readFileSync, writeFileSync, existsSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * 判断"本文件是否被直接执行"（而不是被 import）。
 *
 * 不能直接比较 `import.meta.url` 与 `argv[1]`：Node 会把模块路径解析成 realpath，
 * 而 argv[1] 保留调用方写的路径。macOS 上 `/tmp` 是 `/private/tmp` 的软链、
 * App 也可能被放在软链目录里，两边一比就永远不相等 —— 表现是"脚本静默什么都不做"。
 * 这里统一取 realpath 再比。
 */
function isDirectRun() {
  if (process.argv[1] === undefined) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

const MARKER = '/* dsh-desktop:auth-disabled */';
const PACKAGE = '@deepseek-ai/dsh-client-connection';

/** 需要改成恒真的方法：方法名 -> 注入的返回语句。 */
const TARGETS = [
  { name: 'isAuthenticated', body: 'return true;' },
  { name: 'authorizeIndex', body: 'return true;' },
];

/** 依次尝试包目录、prefix/node_modules 两种入口。 */
function resolveModuleFile(target) {
  const candidates = [
    join(target, 'lib', 'index.js'),
    join(target, 'node_modules', PACKAGE, 'lib', 'index.js'),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  throw new Error(`找不到 ${PACKAGE}/lib/index.js（在 ${target} 下）`);
}

/**
 * 在方法体开头注入 return，使其恒真。
 *
 * 只匹配"方法定义"形态：换行 + 缩进 + 方法名 + 参数 + `{`。
 * 调用点形如 `this.browserAuth.isAuthenticated(request)`，前面带点号，不会被误伤。
 *
 * 同名方法可能有多个定义（例如 BrowserAuth.authorizeIndex 与 Host 侧那个纯转发
 * 的同名方法），它们都在这条认证链上，语义都是"放行"，因此逐个注入。
 */
function patchMethod(source, { name, body }) {
  const pattern = new RegExp(`(^|\\n)([ \\t]*)${name}\\s*\\(([^)]*)\\)\\s*\\{`, 'gu');
  const matches = source.match(pattern);
  if (matches === null) return { source, count: 0 };
  const patched = source.replace(
    pattern,
    (_match, lead, indent, params) => `${lead}${indent}${name}(${params}) { ${MARKER} ${body}`,
  );
  return { source: patched, count: matches.length };
}

function main(argv) {
  const target = argv[0];
  if (target === undefined) {
    process.stderr.write('用法: node patch-dsh-auth.js <运行时目录 | dsh 包目录>\n');
    return 2;
  }
  const file = resolveModuleFile(target);
  const original = readFileSync(file, 'utf8');

  if (original.includes(MARKER)) {
    process.stdout.write(`[patch-dsh-auth] 已打过补丁，跳过: ${file}\n`);
    return 0;
  }

  let source = original;
  const patched = [];
  for (const targetMethod of TARGETS) {
    const result = patchMethod(source, targetMethod);
    if (result.count === 0) {
      process.stderr.write(
        `[patch-dsh-auth] 补丁失败: 未找到方法定义 ${targetMethod.name}(...)\n` +
          '上游实现可能已变更，请更新 scripts/patch-dsh-auth.js 后重新构建。\n',
      );
      return 1;
    }
    source = result.source;
    patched.push(`${targetMethod.name}×${String(result.count)}`);
  }

  // 复核：每个目标方法都必须真的带着补丁标记与注入语句。
  const injected = TARGETS.filter(({ body }) => source.includes(`${MARKER} ${body}`));
  if (injected.length !== TARGETS.length) {
    process.stderr.write('[patch-dsh-auth] 补丁复核失败：注入未全部落地\n');
    return 1;
  }

  writeFileSync(file, source);
  process.stdout.write(
    `[patch-dsh-auth] 已关闭浏览器信任认证 (${patched.join(', ')}): ${file}\n`,
  );
  return 0;
}

if (isDirectRun()) {
  try {
    process.exit(main(process.argv.slice(2)));
  } catch (error) {
    process.stderr.write(`[patch-dsh-auth] ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  }
}

export { resolveModuleFile };
