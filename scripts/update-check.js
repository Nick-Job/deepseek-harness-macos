#!/usr/bin/env node
/*
 * update-check.js — App 内置的"版本更新核查 + dsh 运行时热更新"
 *
 * 为什么需要它：桌面 App 把某个 dsh 版本固化在 bundle 里，而 dsh 上游迭代很快
 * （几乎每天都有 rc）。只靠"重新下载 App"来跟版本，用户永远落后。
 * 这里让 App 自己盯着上游：发现新版本就把新 dsh 装到用户可写的覆盖运行时里，
 * 下次启动自动生效——不用换 App、不用终端的任何命令。
 *
 * 目录约定（都在用户的 Application Support 下，不碰 App bundle 本身）：
 *   <support>/runtime/            覆盖运行时（新装好的 dsh），优先于 App 内置运行时
 *   <support>/runtime.staging/    安装暂存目录，装完并验收通过才原子替换上去
 *   <support>/update-state.json   上次核查时间、已通知过的版本、已装版本
 *   <support>/update.lock         防并发安装
 *
 * 模式:
 *   resolve-runtime   打印应当使用的运行时目录（比较"覆盖"与"内置"谁更新）
 *   status            打印当前 App/内置 dsh/覆盖 dsh 版本（不联网）
 *   latest            只查上游最新版（不碰本地状态）
 *   check             限流核查；发现新版则提示（默认模式）
 *   auto              = check + 自动把新 dsh 装进覆盖运行时
 *   install [版本]     强制安装（不带版本则装上游最新版）
 *
 * 环境变量:
 *   DSH_DESKTOP_SUPPORT_DIR       覆盖 support 目录
 *   DSH_DESKTOP_CHANNEL           npm 渠道，默认 latest
 *   DSH_DESKTOP_AUTO_UPDATE=0     关闭自动热更新（仍会核查与提示）
 *   DSH_DESKTOP_NO_NOTIFY=1       完全静默，只写日志
 *   DSH_DESKTOP_CHECK_HOURS       核查间隔小时数，默认 12
 */

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, symlinkSync, renameSync, openSync, closeSync, realpathSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { compareVersions, bundledVersion, latestVersion } from './dsh-versions.js';

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

// 直接被启动壳执行时，用 argv[1] 的"字面路径"定位 Resources：
// import.meta.url 是 realpath 解析后的结果，App 若位于软链路径下会指到别处。
const SCRIPT_DIR = isDirectRun() ? dirname(resolve(process.argv[1])) : dirname(fileURLToPath(import.meta.url));
const RESOURCES_DIR = resolve(SCRIPT_DIR, '..');
const REPO = 'Nick-Job/deepseek-harness-macos';
const PACKAGE = '@deepseek-ai/dsh';

const SUPPORT_DIR =
  process.env.DSH_DESKTOP_SUPPORT_DIR ?? join(homedir(), 'Library', 'Application Support', 'DeepSeek Harness');
const STATE_FILE = join(SUPPORT_DIR, 'update-state.json');
const LOCK_FILE = join(SUPPORT_DIR, 'update.lock');
const OVERLAY_DIR = join(SUPPORT_DIR, 'runtime');
const STAGING_DIR = join(SUPPORT_DIR, 'runtime.staging');
const LOG_FILE = process.env.DSH_DESKTOP_LOG ?? join(homedir(), 'Library', 'Logs', 'deepseek-harness-dsh.log');
const CHANNEL = process.env.DSH_DESKTOP_CHANNEL ?? 'latest';
const CHECK_HOURS = Number(process.env.DSH_DESKTOP_CHECK_HOURS ?? 12);
const QUIET = process.env.DSH_DESKTOP_NO_NOTIFY === '1';

/** 追加一行日志；日志是用户排查问题的唯一入口，任何失败都不该让它崩掉。 */
function log(message) {
  const line = `[${new Date().toISOString().replace('T', ' ').slice(0, 19)}] update: ${message}\n`;
  try {
    mkdirSync(dirname(LOG_FILE), { recursive: true });
    writeFileSync(LOG_FILE, line, { flag: 'a' });
  } catch {
    /* 日志写不进去也不能影响主流程 */
  }
  if (process.env.DSH_DESKTOP_VERBOSE === '1') process.stdout.write(line);
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return undefined;
  }
}

/** 读取一个运行时目录里的 dsh 版本。 */
function runtimeVersion(dir) {
  return bundledVersion(dir);
}

function state() {
  return readJson(STATE_FILE) ?? {};
}

function saveState(patch) {
  const merged = { ...state(), ...patch };
  try {
    mkdirSync(SUPPORT_DIR, { recursive: true });
    writeFileSync(STATE_FILE, `${JSON.stringify(merged, null, 2)}\n`);
  } catch (error) {
    log(`状态文件写入失败: ${error instanceof Error ? error.message : String(error)}`);
  }
  return merged;
}

/** macOS 通知（不抢焦点，不阻塞）。 */
function notify(title, message) {
  if (QUIET) return;
  const quoted = (value) => `"${String(value).replace(/\\/gu, '\\\\').replace(/"/gu, '\\"')}"`;
  spawnSync('osascript', ['-e', `display notification ${quoted(message)} with title ${quoted(title)}`], {
    timeout: 10_000,
  });
}

/** 带按钮的对话框；返回用户点的按钮文案，超时或失败返回 undefined。 */
function ask(title, message, buttons) {
  if (QUIET) return undefined;
  const quoted = (value) => `"${String(value).replace(/\\/gu, '\\\\').replace(/"/gu, '\\"')}"`;
  const buttonList = `{${buttons.map(quoted).join(', ')}}`;
  const script = `display dialog ${quoted(message)} with title ${quoted(title)} buttons ${buttonList} default button ${quoted(buttons[0])} with icon note`;
  const result = spawnSync('osascript', ['-e', script], { timeout: 180_000, encoding: 'utf8' });
  if (result.status !== 0) return undefined;
  const match = /button returned:(.+)$/mu.exec(result.stdout.trim());
  return match?.[1];
}

/** 查 GitHub 上本仓库的最新 release；失败（离线/限流）返回 undefined。 */
async function latestRelease() {
  try {
    const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { accept: 'application/vnd.github+json', 'user-agent': 'dsh-desktop-update-check' },
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) return undefined;
    const body = await response.json();
    const tag = typeof body.tag_name === 'string' ? body.tag_name.replace(/^v/u, '') : undefined;
    if (tag === undefined) return undefined;
    return { version: tag, url: typeof body.html_url === 'string' ? body.html_url : `https://github.com/${REPO}/releases` };
  } catch {
    return undefined;
  }
}

/** App 自身的版本与内置 dsh 版本（构建记录由 bundle-runtime.sh 写在 runtime/version.json）。 */
function appInfo() {
  const manifest = readJson(join(RESOURCES_DIR, 'runtime', 'version.json')) ?? readJson(join(RESOURCES_DIR, 'version.json')) ?? {};
  return {
    appVersion: typeof manifest.appVersion === 'string' ? manifest.appVersion : '0.0.0',
    bundledDsh: runtimeVersion(join(RESOURCES_DIR, 'runtime')) ?? (typeof manifest.dshVersion === 'string' ? manifest.dshVersion : undefined),
    builtAt: manifest.builtAt,
    channel: manifest.channel,
  };
}

/**
 * 决定用哪个运行时：覆盖运行时（热更新装上的）与 App 内置运行时取版本较高的那个。
 *
 * 内置运行时本来可能比覆盖的更新（用户刚换了新版 App），此时覆盖运行时就是垃圾，
 * 顺手清掉，免得它一直压着新版本。
 *
 * @returns {{ dir: string, source: 'overlay'|'bundled', version: string|undefined, pruned?: string }}
 */
function resolveRuntime() {
  const bundledDir = join(RESOURCES_DIR, 'runtime');
  const bundled = runtimeVersion(bundledDir);
  const overlay = runtimeVersion(OVERLAY_DIR);
  const usableOverlay =
    overlay !== undefined && existsSync(join(OVERLAY_DIR, 'bin', 'node')) && existsSync(join(OVERLAY_DIR, 'node_modules', PACKAGE, 'lib', 'bin.js'));

  if (!usableOverlay) {
    return { dir: bundledDir, source: 'bundled', version: bundled };
  }
  if (bundled !== undefined && compareVersions(bundled, overlay) > 0) {
    // 内置的更新：废弃覆盖运行时
    try {
      rmSync(OVERLAY_DIR, { recursive: true, force: true });
      log(`内置运行时(${bundled})比覆盖运行时(${overlay})新，已清理覆盖运行时`);
    } catch (error) {
      log(`清理过期覆盖运行时失败: ${error instanceof Error ? error.message : String(error)}`);
    }
    return { dir: bundledDir, source: 'bundled', version: bundled, pruned: overlay };
  }
  return { dir: OVERLAY_DIR, source: 'overlay', version: overlay };
}

/** 简单的进程级互斥：拿到锁才允许安装。 */
function withLock(fn) {
  mkdirSync(SUPPORT_DIR, { recursive: true });
  let fd;
  try {
    fd = openSync(LOCK_FILE, 'wx');
  } catch {
    // 老锁可能是上次被强杀留下的，超过 1 小时视为失效
    const existing = readJson(LOCK_FILE);
    const startedAt = typeof existing?.startedAt === 'string' ? Date.parse(existing.startedAt) : 0;
    if (Number.isFinite(startedAt) && Date.now() - startedAt < 3_600_000) {
      log('已有另一个更新进程在跑，跳过本次安装');
      return undefined;
    }
    rmSync(LOCK_FILE, { force: true });
    try {
      fd = openSync(LOCK_FILE, 'wx');
    } catch {
      return undefined;
    }
  }
  writeFileSync(LOCK_FILE, `${JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() })}\n`);
  closeSync(fd);
  try {
    return fn();
  } finally {
    rmSync(LOCK_FILE, { force: true });
  }
}

/** 用 App 内置的 node/npm 把指定版本装到覆盖运行时并验收。 */
function installDsh(targetVersion) {
  const nodeBin = join(RESOURCES_DIR, 'runtime', 'bin', 'node');
  const npmCli = join(RESOURCES_DIR, 'runtime', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js');
  if (!existsSync(nodeBin) || !existsSync(npmCli)) {
    throw new Error('找不到内置 node/npm，无法热更新');
  }

  return withLock(() => {
    log(`开始安装 dsh@${targetVersion} 到覆盖运行时 ...`);
    rmSync(STAGING_DIR, { recursive: true, force: true });
    mkdirSync(STAGING_DIR, { recursive: true });

    // 只把 dsh 装进暂存目录；node/npm 本体用软链复用 App 内置的，避免重复上百 MB。
    for (const entry of ['bin', 'lib']) {
      const link = join(STAGING_DIR, entry);
      rmSync(link, { recursive: true, force: true });
      symlinkSync(join(RESOURCES_DIR, 'runtime', entry), link);
    }

    const npmCache = join(SUPPORT_DIR, 'npm-cache');
    mkdirSync(npmCache, { recursive: true });
    const install = spawnSync(
      nodeBin,
      [npmCli, 'install', '--prefix', STAGING_DIR, '--cache', npmCache, '--no-audit', '--no-fund', '--loglevel=error', `${PACKAGE}@${targetVersion}`],
      {
        encoding: 'utf8',
        timeout: 20 * 60_000,
        env: { ...process.env, NODE_OPTIONS: '--max-old-space-size=4096', PATH: `${join(RESOURCES_DIR, 'runtime', 'bin')}:${process.env.PATH ?? ''}` },
      },
    );
    if (install.status !== 0) {
      throw new Error(`npm install 失败(exit=${String(install.status)}): ${(install.stderr ?? '').trim().split('\n').slice(-3).join(' | ')}`);
    }

    const installed = runtimeVersion(STAGING_DIR);
    if (installed === undefined) throw new Error('安装完成但读不到 dsh 版本');

    // 新版 dsh 的浏览器信任认证必须同样关掉，否则 Pake 壳会撞 401
    const patch = spawnSync(nodeBin, [join(SCRIPT_DIR, 'patch-dsh-auth.js'), STAGING_DIR], { encoding: 'utf8', timeout: 60_000 });
    if (patch.status !== 0) throw new Error(`认证补丁失败: ${(patch.stderr ?? '').trim()}`);

    // 行为级验收：首页无 cookie 必须 200，且不得打开浏览器
    const smoke = spawnSync('/bin/bash', [join(SCRIPT_DIR, 'smoke-test.sh'), '--runtime-dir', STAGING_DIR], {
      encoding: 'utf8',
      timeout: 5 * 60_000,
    });
    if (smoke.status !== 0) {
      throw new Error(`冒烟测试未通过: ${(smoke.stderr ?? smoke.stdout ?? '').trim().split('\n').slice(-2).join(' | ')}`);
    }

    writeFileSync(
      join(STAGING_DIR, 'version.json'),
      `${JSON.stringify(
        {
          appVersion: appInfo().appVersion,
          dshVersion: installed,
          channel: CHANNEL,
          source: 'in-app-update',
          builtAt: new Date().toISOString(),
        },
        null,
        2,
      )}\n`,
    );

    // 原子替换：装好的才上台，失败时原地保留旧运行时
    const previous = `${OVERLAY_DIR}.previous`;
    rmSync(previous, { recursive: true, force: true });
    if (existsSync(OVERLAY_DIR)) renameSync(OVERLAY_DIR, previous);
    renameSync(STAGING_DIR, OVERLAY_DIR);
    rmSync(previous, { recursive: true, force: true });

    log(`dsh 已热更新到 ${installed}（下次启动生效）`);
    saveState({ installedDsh: installed, installedAt: new Date().toISOString(), lastError: undefined });
    notify('DeepSeek Harness 已更新', `内置 dsh 已更新到 ${installed}，下次打开生效。`);
    return installed;
  });
}

/** 核查 + 提示；autoInstall 时把新版本装进覆盖运行时。 */
async function check({ autoInstall }) {
  const info = appInfo();
  const active = resolveRuntime();
  const now = Date.now();
  const previous = state();
  const lastCheck = typeof previous.lastCheck === 'string' ? Date.parse(previous.lastCheck) : 0;
  const throttled = Number.isFinite(lastCheck) && now - lastCheck < CHECK_HOURS * 3_600_000;
  if (!process.argv.includes('--force') && throttled) {
    return { skipped: 'throttled', active, info };
  }

  let upstreamDsh;
  try {
    upstreamDsh = await latestVersion(CHANNEL);
  } catch (error) {
    log(`查询 npm 失败: ${error instanceof Error ? error.message : String(error)}`);
  }

  const release = await latestRelease();
  const currentDsh = active.version;
  const dshOutdated = upstreamDsh !== undefined && currentDsh !== undefined && compareVersions(upstreamDsh, currentDsh) > 0;
  const appOutdated = release !== undefined && compareVersions(release.version, info.appVersion) > 0;

  saveState({
    lastCheck: new Date().toISOString(),
    channel: CHANNEL,
    activeRuntime: active.source,
    activeDsh: currentDsh,
    upstreamDsh,
    upstreamApp: release?.version,
    appVersion: info.appVersion,
  });

  log(
    `核查完成: 内置 dsh=${currentDsh ?? '未知'}(用 ${active.source})，上游 dsh=${upstreamDsh ?? '查询失败'}，` +
      `本机 App=${info.appVersion}，上游 App=${release?.version ?? '查询失败'}`,
  );

  if (dshOutdated && autoInstall && process.env.DSH_DESKTOP_AUTO_UPDATE !== '0') {
    try {
      await Promise.resolve(installDsh(upstreamDsh));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      log(`自动更新失败（不影响当前使用）: ${message}`);
      saveState({ lastError: message });
      notify('DeepSeek Harness 更新失败', '内置 dsh 更新没成功，可继续正常使用；详情见日志。');
    }
  } else if (dshOutdated) {
    notify('DeepSeek Harness 有新版本 dsh', `上游已发布 dsh ${upstreamDsh}（当前 ${currentDsh ?? '未知'}）。`);
  }

  if (appOutdated) {
    const answer = ask(
      'DeepSeek Harness 有新版本',
      `App 有新版本 ${release.version}（当前 ${info.appVersion}）。\n内置 dsh 会自动跟随更新，App 壳本身需要重新下载安装。`,
      ['稍后', '打开发布页'],
    );
    if (answer === '打开发布页') spawnSync('/usr/bin/open', [release.url], { timeout: 15_000 });
    saveState({ notifiedAppVersion: release.version });
  }

  return { active, info, upstreamDsh, release, dshOutdated, appOutdated };
}

async function main() {
  const [mode = 'check'] = process.argv.slice(2).filter((argument) => !argument.startsWith('--'));
  const json = process.argv.includes('--json');

  switch (mode) {
    case 'resolve-runtime': {
      const active = resolveRuntime();
      if (json) process.stdout.write(`${JSON.stringify(active)}\n`);
      else process.stdout.write(`${active.dir}\n`);
      return 0;
    }
    case 'status': {
      const active = resolveRuntime();
      const info = appInfo();
      const payload = {
        appVersion: info.appVersion,
        bundledDsh: runtimeVersion(join(RESOURCES_DIR, 'runtime')),
        overlayDsh: runtimeVersion(OVERLAY_DIR),
        activeRuntime: active.source,
        activeDir: active.dir,
        activeDsh: active.version,
        state: state(),
      };
      process.stdout.write(`${JSON.stringify(payload, null, json ? 2 : 0)}\n`);
      return 0;
    }
    case 'latest': {
      const upstreamDsh = await latestVersion(CHANNEL);
      const release = await latestRelease();
      process.stdout.write(`${JSON.stringify({ channel: CHANNEL, dshVersion: upstreamDsh, appVersion: release?.version, releaseUrl: release?.url })}\n`);
      return 0;
    }
    case 'install': {
      const explicit = process.argv.slice(2).find((argument) => /^\d+\.\d+\.\d+/u.test(argument));
      const target = explicit ?? (await latestVersion(CHANNEL));
      const installed = installDsh(target);
      if (installed === undefined) {
        log('安装被跳过（已有更新进程在运行）');
        return 0;
      }
      process.stdout.write(`${installed}\n`);
      return 0;
    }
    case 'auto':
    case 'check': {
      const result = await check({ autoInstall: mode === 'auto' });
      if (json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      return 0;
    }
    default:
      process.stderr.write('用法: update-check.js [resolve-runtime|status|latest|check|auto|install] [--force] [--json]\n');
      return 2;
  }
}

export { resolveRuntime, installDsh, appInfo };

// 被 App/启动壳调用时才执行；被 import（测试）时不执行。
if (isDirectRun()) {
  main().then(
    (code) => process.exit(code),
    (error) => {
      // 更新核查永远不该让 App 起不来
      log(`未处理异常: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
      process.exit(0);
    },
  );
}
