#!/usr/bin/env node
// 把 dist/ 里的产物发布到 GitHub Release，并把清单需要的下载地址打出来。
//
// 只依赖 node 内置模块 + 系统 curl：curl 负责真正的网络请求，所以能用
// --proxy / HTTPS_PROXY 走本机代理（Node 内置 fetch 不读代理环境变量）。
//
// 用法：
//   node scripts/publish-github.mjs plan                     # 只看要做什么
//   node scripts/publish-github.mjs release --notes-file x   # 建/改 Release
//   node scripts/publish-github.mjs upload                   # 传缺失的资产
//   node scripts/publish-github.mjs verify                   # 校验摘要 + 可下载
//   node scripts/publish-github.mjs all                      # 以上三步
//
// 令牌：--token、环境变量 GITHUB_TOKEN，或 .local/gh.json 的 {"token": "..."}。
// 令牌只从这三个来源读，不打印、不写日志、不入库。

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
const command = argv[0] || 'plan';

function flag(name, fallback = undefined) {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : fallback;
}

const dryRun = argv.includes('--dry-run');
const repo = flag('--repo', process.env.GITHUB_REPO || 'Hanc/Hongguo-video-pack');
const proxy = flag('--proxy', process.env.HTTPS_PROXY || process.env.GITHUB_PROXY || '');
const notesFile = flag('--notes-file');
const prerelease = argv.includes('--prerelease');
const CURL = process.platform === 'win32' ? 'curl.exe' : 'curl';

function version() {
  if (flag('--version')) return flag('--version');
  const text = readFileSync(join(root, 'lib', 'app_version.dart'), 'utf8');
  const hit = /appVersion\s*=\s*'([^']+)'/.exec(text);
  if (!hit) throw new Error('读不到 lib/app_version.dart 里的 appVersion');
  return hit[1];
}

function token() {
  if (flag('--token')) return flag('--token');
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN;
  const path = join(root, '.local', 'gh.json');
  if (!existsSync(path)) {
    throw new Error('缺少凭据：--token / GITHUB_TOKEN / .local/gh.json 三者之一');
  }
  const parsed = JSON.parse(readFileSync(path, 'utf8'));
  if (!parsed.token) throw new Error('.local/gh.json 里没有 token 字段');
  return parsed.token;
}

function digests(file) {
  const hash = createHash('sha256');
  hash.update(readFileSync(file));
  return hash.digest('hex');
}

// 一次 curl，返回 { status, text }。body 用文件传，避免命令行长度与转义问题。
function curl(args, { timeout = 300, bodyFile, outFile } = {}) {
  const full = ['-sS', '-m', String(timeout)];
  if (proxy) full.push('--proxy', proxy);
  full.push(...args);
  if (bodyFile) full.push('--data-binary', `@${bodyFile}`);
  if (outFile) full.push('-o', outFile, '-w', '%{http_code}');
  const started = Date.now();
  const out = execFileSync(CURL, full, {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const text = outFile ? readFileSync(outFile, 'utf8') : out;
  const status = outFile ? Number(out.trim()) : 0;
  return { status, text, ms: Date.now() - started };
}

function api(method, path, { json, accept = 'application/vnd.github+json', timeout = 120 } = {}) {
  const args = ['-X', method, '-H', `Authorization: Bearer ${token()}`, '-H', `Accept: ${accept}`];
  let bodyFile;
  if (json) {
    args.push('-H', 'Content-Type: application/json');
    bodyFile = join(root, '.local', 'gh-request.json');
    writeFileSync(bodyFile, JSON.stringify(json), 'utf8');
  }
  const outFile = join(root, '.local', 'gh-response.json');
  const res = curl([...args, `https://api.github.com${path}`], { bodyFile, outFile, timeout });
  let parsed;
  try {
    parsed = JSON.parse(res.text || 'null');
  } catch {
    parsed = null;
  }
  return { status: res.status, json: parsed, raw: res.text, ms: res.ms };
}

function assets(ver, { platform } = {}) {
  const dist = join(root, 'dist');
  if (!existsSync(dist)) throw new Error('dist/ 不存在，先跑 dev.ps1 dist');
  const all = readdirSync(dist)
    .filter((name) => name.includes(ver) && /\.(exe|apk|zip)$/i.test(name))
    .map((name) => {
      const path = join(dist, name);
      const size = statSync(path).size;
      const kind = name.endsWith('.apk')
        ? 'android'
        : name.endsWith('.exe')
          ? 'windows'
          : name.includes('Source')
            ? 'source'
            : 'windows-zip';
      return { name, path, size, kind, sha256: digests(path) };
    })
    .filter((item) => !platform || item.kind === platform);
  if (all.length === 0) throw new Error(`dist/ 里没有 ${ver} 的产物`);
  return all;
}

function ensureRelease(ver) {
  const tag = `v${ver}`;
  const found = api('GET', `/repos/${repo}/releases/tags/${tag}`);
  if (found.status === 200) {
    console.log(`Release ${tag} 已存在（id ${found.json.id}，资产 ${found.json.assets.length} 个）`);
    return found.json;
  }
  if (found.status !== 404) throw new Error(`查询 Release 失败：HTTP ${found.status}`);
  const body = notesFile ? readFileSync(resolve(root, notesFile), 'utf8') : `红葡萄 ${ver}`;
  const created = api('POST', `/repos/${repo}/releases`, {
    json: { tag_name: tag, name: `红葡萄 ${ver}`, body, prerelease, draft: false },
  });
  if (created.status !== 201) throw new Error(`创建 Release 失败：HTTP ${created.status} ${created.raw.slice(0, 200)}`);
  console.log(`已创建 Release ${tag}（id ${created.json.id}）`);
  return created.json;
}

function uploadAssets(ver, release) {
  const existing = new Map(release.assets.map((asset) => [asset.name, asset]));
  const upload = `https://uploads.github.com/repos/${repo}/releases/${release.id}/assets`;
  const uploaded = [];
  for (const item of assets(ver)) {
    const have = existing.get(item.name);
    if (have && have.size === item.size) {
      console.log(`跳过（已存在同名同大小）：${item.name}`);
      uploaded.push({ ...item, url: have.browser_download_url, digest: have.digest });
      continue;
    }
    if (have) {
      console.log(`同名但大小不同，先删旧的：${item.name}`);
      const del = api('DELETE', `/repos/${repo}/releases/assets/${have.id}`);
      if (del.status !== 204) throw new Error(`删除旧资产失败：HTTP ${del.status}`);
    }
    if (dryRun) {
      console.log(`[dry-run] 会上传 ${item.name}（${(item.size / 1048576).toFixed(1)} MB）`);
      continue;
    }
    console.log(`上传 ${item.name}（${(item.size / 1048576).toFixed(1)} MB）…`);
    const res = curl(
      [
        '-X',
        'POST',
        '-H',
        `Authorization: Bearer ${token()}`,
        '-H',
        'Content-Type: application/octet-stream',
        `${upload}?name=${encodeURIComponent(item.name)}`,
      ],
      { timeout: 1800, bodyFile: item.path, outFile: join(root, '.local', 'gh-upload.json') },
    );
    const parsed = JSON.parse(res.text || '{}');
    if (res.status !== 201 || !parsed.browser_download_url) {
      throw new Error(`上传 ${item.name} 失败：HTTP ${res.status} ${res.text.slice(0, 200)}`);
    }
    console.log(`  ${(res.ms / 1000).toFixed(1)}s → ${parsed.digest || '（无 digest）'}`);
    uploaded.push({ ...item, url: parsed.browser_download_url, digest: parsed.digest });
  }
  return uploaded;
}

async function verifyAssets(uploaded) {
  let bad = 0;
  const probeFile = join(root, '.local', 'gh-probe.bin');
  const fresh = api('GET', `/repos/${repo}/releases/tags/v${version()}`);
  const byName = new Map((fresh.json?.assets || []).map((asset) => [asset.name, asset]));
  for (const item of uploaded) {
    const remote = byName.get(item.name);
    if (!remote) {
      console.log(`✗ ${item.name} 远端不存在`);
      bad += 1;
      continue;
    }
    const digestOk = !remote.digest || remote.digest === `sha256:${item.sha256}`;
    const sizeOk = remote.size === item.size;
    // 资产地址会 302 到对象存储，-L 跟到底，用单字节 Range 确认真的能下。
    const res = curl(['-L', '-r', '0-0', '-H', 'Accept: application/octet-stream', remote.browser_download_url], {
      timeout: 180,
      outFile: probeFile,
    });
    const bytes = existsSync(probeFile) ? statSync(probeFile).size : 0;
    const dlOk = (res.status === 200 || res.status === 206) && bytes > 0;
    const ok = digestOk && sizeOk && dlOk;
    if (!ok) bad += 1;
    console.log(
      `${ok ? '✓' : '✗'} ${item.name}  size=${remote.size}/${item.size}  ` +
        `digest=${(remote.digest || 'none').replace('sha256:', '').slice(0, 12)}…  ` +
        `GET=${res.status}/${bytes}B`,
    );
  }
  if (bad > 0) throw new Error(`${bad} 个资产校验失败`);
}

function manifestCommands(uploaded, ver) {
  const pick = (kind) => uploaded.find((item) => item.kind === kind);
  const apk = pick('android');
  const exe = pick('windows');
  console.log('\n清单（latest.json 仍留在 COS，只把 url 指向 Release）：');
  if (apk) {
    console.log(
      `  node scripts/publish-cos.mjs push-android dist/${apk.name} --skip-upload --package-url ${apk.url} --notes "说明"`,
    );
  }
  if (exe) {
    console.log(
      `  node scripts/publish-cos.mjs push-windows dist/${exe.name} --skip-upload --package-url ${exe.url} --notes "说明"`,
    );
  }
  console.log(`\n版本：${ver}`);
}

try {
  const ver = version();
  if (command === 'plan') {
    console.log(`仓库 ${repo}，版本 ${ver}${proxy ? `，代理 ${proxy}` : '（未设代理）'}${dryRun ? '，dry-run' : ''}`);
    for (const item of assets(ver)) {
      console.log(`  ${(item.size / 1048576).toFixed(1).padStart(6)} MB  ${item.kind.padEnd(10)} ${item.name}`);
      console.log(`              sha256 ${item.sha256}`);
    }
  } else if (command === 'release') {
    ensureRelease(ver);
  } else if (command === 'upload') {
    const release = ensureRelease(ver);
    uploadAssets(ver, release);
  } else if (command === 'verify') {
    await verifyAssets(assets(ver));
  } else if (command === 'all') {
    const release = ensureRelease(ver);
    const uploaded = uploadAssets(ver, release);
    await verifyAssets(uploaded);
    manifestCommands(uploaded, ver);
  } else {
    console.error('用法：plan | release | upload | verify | all  [--dry-run] [--repo o/n] [--proxy url] [--notes-file path] [--version x] [--prerelease]');
    process.exit(2);
  }
} catch (error) {
  console.error(`失败：${error.message}`);
  process.exit(1);
}
