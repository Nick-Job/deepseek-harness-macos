#!/usr/bin/env node
/*
 * dsh-versions.js — 上游 dsh 版本的唯一查询/比较入口。
 *
 * 构建时（bundle-runtime.sh、GitHub Actions）和运行时（App 内的更新核查）
 * 都从这里取"最新版是多少"，避免多处实现各写一套判断。
 *
 * 用法:
 *   node dsh-versions.js latest [channel]   # 打印 npm dist-tag 指向的版本，默认 channel=latest
 *   node dsh-versions.js compare A B        # A 比 B: 打印 newer | older | equal
 *   node dsh-versions.js newer A B          # A 比 B 新时退出码 0，否则 1
 *   node dsh-versions.js bundled <dir>      # 打印某个 dsh 安装目录里的版本
 */

import { readFileSync, realpathSync } from 'node:fs';
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

const PACKAGE = '@deepseek-ai/dsh';
const REGISTRY = 'https://registry.npmjs.org';

/** 去掉前导 v 并按 `-` 拆出预发布段。 */
function parseVersion(raw) {
  const text = String(raw ?? '').trim().replace(/^v/u, '');
  const [core = '', ...rest] = text.split('-');
  const numbers = core.split('.').map((part) => {
    const value = Number.parseInt(part, 10);
    return Number.isFinite(value) ? value : 0;
  });
  while (numbers.length < 3) numbers.push(0);
  return { numbers, prerelease: rest.join('-') };
}

/**
 * 比较两个版本号。
 *
 * 预发布段的规则比 semver 宽松一档：同为预发布时按每段逐项比（数字按数值、
 * 其他按字典序），installer 只需要"该不该升"这一个答案。
 *
 * @returns {number} a 比 b 新返回 1，旧返回 -1，相同返回 0。
 */
export function compareVersions(a, b) {
  const left = parseVersion(a);
  const right = parseVersion(b);
  for (let index = 0; index < 3; index += 1) {
    if (left.numbers[index] !== right.numbers[index]) {
      return left.numbers[index] > right.numbers[index] ? 1 : -1;
    }
  }
  if (left.prerelease === right.prerelease) return 0;
  if (left.prerelease === '') return 1;
  if (right.prerelease === '') return -1;
  const leftParts = left.prerelease.split('.');
  const rightParts = right.prerelease.split('.');
  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    const l = leftParts[index];
    const r = rightParts[index];
    if (l === undefined) return -1;
    if (r === undefined) return 1;
    if (l === r) continue;
    const lNumber = Number.parseInt(l, 10);
    const rNumber = Number.parseInt(r, 10);
    const bothNumeric = String(lNumber) === l && String(rNumber) === r;
    if (bothNumeric) return lNumber > rNumber ? 1 : -1;
    return l > r ? 1 : -1;
  }
  return 0;
}

/** 读取一个 dsh 安装目录（prefix 或包目录）里的版本号。 */
export function bundledVersion(target) {
  const candidates = [
    join(target, 'package.json'),
    join(target, 'node_modules', PACKAGE, 'package.json'),
  ];
  for (const candidate of candidates) {
    try {
      const manifest = JSON.parse(readFileSync(candidate, 'utf8'));
      if (manifest.name === PACKAGE) return String(manifest.version);
    } catch {
      /* 换下一个候选路径 */
    }
  }
  return undefined;
}

/** 查询 npm dist-tag 指向的版本。 */
export async function latestVersion(channel = 'latest', timeoutMs = 15_000) {
  const response = await fetch(`${REGISTRY}/${PACKAGE.replace('/', '%2F')}`, {
    headers: { accept: 'application/vnd.npm.install-v1+json, application/json' },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`npm registry 返回 ${String(response.status)}`);
  const body = await response.json();
  const tags = body['dist-tags'] ?? {};
  const resolved = tags[channel];
  if (typeof resolved !== 'string' || resolved === '') {
    throw new Error(`npm 上没有 dist-tag ${channel}（现有: ${Object.keys(tags).join(', ')}）`);
  }
  return resolved;
}

async function main(argv) {
  const [command, ...rest] = argv;
  switch (command) {
    case 'latest': {
      process.stdout.write(`${await latestVersion(rest[0] ?? 'latest')}\n`);
      return 0;
    }
    case 'bundled': {
      const version = bundledVersion(rest[0] ?? '.');
      if (version === undefined) throw new Error(`在 ${rest[0] ?? '.'} 里找不到 ${PACKAGE}`);
      process.stdout.write(`${version}\n`);
      return 0;
    }
    case 'compare':
    case 'newer': {
      const [a, b] = rest;
      if (a === undefined || b === undefined) throw new Error(`${command} 需要两个版本号`);
      const result = compareVersions(a, b);
      if (command === 'compare') {
        process.stdout.write(`${result > 0 ? 'newer' : result < 0 ? 'older' : 'equal'}\n`);
        return 0;
      }
      return result > 0 ? 0 : 1;
    }
    default:
      process.stderr.write(
        '用法: node dsh-versions.js latest [channel] | compare A B | newer A B | bundled <dir>\n',
      );
      return 2;
  }
}

// 仅在直接执行时跑 CLI；被 import 时不触发。
if (isDirectRun()) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (error) => {
      process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
      process.exit(1);
    },
  );
}
