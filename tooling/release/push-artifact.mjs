#!/usr/bin/env node
// 发布机侧的安装包推送器：分片上传 + 断点续传 + 可达性验证。零依赖，Node 18+。
//
//   HONGGUO_UPLOAD_TOKEN=xxx node push-artifact.mjs dist\Hongputao-Android-arm64-0.11.1.apk \
//     --base https://dl.example.com --key updates/android/Hongputao-Android-arm64-0.11.1-2022760d.apk
//
//   --dry-run   只算计划（哈希/分片数/目标地址），不联网、不需要令牌
//   --json      末尾输出一行 JSON（父进程解析用）
import { createHash } from 'node:crypto';
import { createReadStream, statSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { basename } from 'node:path';

function flag(name) {
  return process.argv.includes(`--${name}`);
}

function option(name, fallback) {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 ? process.argv[at + 1] : fallback;
}

const file = process.argv[2];
const key = option('key', '');
const base = (option('base', process.env.HONGGUO_SERVER_BASE || '') || '').replace(/\/+$/, '');
const token = option('token', process.env.HONGGUO_UPLOAD_TOKEN || '');
const chunkBytes = Math.max(1, Number(option('chunk-mb', 8))) * 1024 * 1024;
const retries = Math.max(0, Number(option('retries', 3)));
const dryRun = flag('dry-run');
const asJson = flag('json');
const timeoutMs = Number(option('timeout-ms', 600000));

if (!file) {
  console.error('用法：push-artifact.mjs <文件> --key updates/<平台>/<文件名> --base https://dl.域名 [--dry-run]');
  process.exit(2);
}
if (!key) {
  console.error('缺少 --key（远端相对路径，形如 updates/android/xxx.apk）');
  process.exit(2);
}
if (!/^updates\/[a-z]+\/[^/]+$/.test(key)) {
  console.error(`--key 必须是 updates/<平台>/<文件名> 的形式，收到：${key}`);
  process.exit(2);
}

const size = statSync(file).size;
const sha256 = await new Promise((resolve, reject) => {
  const digest = createHash('sha256');
  createReadStream(file)
    .on('data', (chunk) => digest.update(chunk))
    .on('end', () => resolve(digest.digest('hex')))
    .on('error', reject);
});
const chunks = size === 0 ? 0 : Math.ceil(size / chunkBytes);

const plan = {
  file: basename(file),
  key,
  size,
  sha256,
  chunkBytes,
  chunks,
  url: base ? `${base}/${key}` : null,
};

if (dryRun) {
  const summary = {
    ok: true,
    dryRun: true,
    ...plan,
    note: base
      ? `计划：向 ${base} 分 ${chunks} 片上传，完成后校验 ${sha256.slice(0, 8)}… 并做 Range 可达性检查`
      : '计划已生成；缺少 --base / HONGGUO_SERVER_BASE，联网步骤不会执行',
  };
  if (asJson) console.log(JSON.stringify(summary));
  else {
    console.log(`文件      ${plan.file}`);
    console.log(`字节      ${size}`);
    console.log(`sha256    ${sha256}`);
    console.log(`分片      ${chunks} × ${(chunkBytes / 1048576).toFixed(1)} MB`);
    console.log(`目标      ${plan.url || '(未配置 --base)'}`);
    console.log('dry-run：不联网、不上传、不写清单');
  }
  process.exit(0);
}

if (!base) {
  console.error('缺少 --base 或环境变量 HONGGUO_SERVER_BASE');
  process.exit(2);
}
if (!token) {
  console.error('缺少令牌：请设置环境变量 HONGGUO_UPLOAD_TOKEN（服务端 --token 的值）');
  process.exit(2);
}

function agentFor(target) {
  return target.protocol === 'http:' ? httpRequest : httpsRequest;
}

/** 单次请求；body 可以是 Buffer 或 {file,start,end} 的流。 */
function call(url, { method = 'GET', headers = {}, body, bodyLength } = {}) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const req = agentFor(target)(
      { host: target.hostname, port: target.port || undefined, path: target.pathname + target.search, method, headers },
      (res) => {
        const buffers = [];
        res.on('data', (chunk) => buffers.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(buffers).toString('utf8');
          let json = null;
          try {
            json = JSON.parse(text);
          } catch {}
          resolve({ status: res.statusCode, headers: res.headers, text, json });
        });
      },
    );
    req.on('error', reject);
    req.setTimeout(timeoutMs, () => req.destroy(new Error('请求超时')));
    if (body && body.file) {
      createReadStream(body.file, { start: body.start, end: body.end }).pipe(req);
      return;
    }
    if (body !== undefined) {
      req.end(body);
      return;
    }
    if (bodyLength !== undefined) req.setHeader('Content-Length', bodyLength);
    req.end();
  });
}

async function withRetry(label, run) {
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await run(attempt);
    } catch (error) {
      lastError = error;
      if (attempt === retries) break;
      await new Promise((done) => setTimeout(done, 500 * (attempt + 1)));
    }
  }
  throw new Error(`${label} 失败：${lastError?.message || lastError}`);
}

const started = Date.now();
let uploads = 0;
let resumes = 0;

const session = await withRetry('创建上传会话', async () => {
  const res = await call(`${base}/upload/session`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ key, size, sha256 }),
  });
  if (res.status === 429) {
    const wait = Number(res.headers['retry-after'] || 60);
    await new Promise((done) => setTimeout(done, Math.min(wait, 60) * 1000));
    throw new Error('被限流，已等待重试');
  }
  if (res.status !== 200 && res.status !== 201) {
    throw new Error(`HTTP ${res.status} ${res.text.slice(0, 200)}`);
  }
  if (res.json?.offset > 0) resumes += 1;
  return res.json;
});

let offset = Number(session.offset || 0);
if (offset > 0) console.log(`从偏移 ${offset} 续传（共 ${size} 字节）`);

while (offset < size) {
  const end = Math.min(offset + chunkBytes, size) - 1;
  const length = end - offset + 1;
  const res = await withRetry(`上传分片 ${offset}-${end}`, async () => {
    const attempt = await call(`${base}/upload/session/${session.sessionId}`, {
      method: 'PUT',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/octet-stream',
        'Content-Length': length,
        'Content-Range': `bytes ${offset}-${end}/${size}`,
      },
      body: { file, start: offset, end },
    });
    if (attempt.status === 409 && attempt.json?.offset !== undefined) {
      return { resync: Number(attempt.json.offset) };
    }
    if (attempt.status !== 202 && attempt.status !== 200) {
      throw new Error(`HTTP ${attempt.status} ${attempt.text.slice(0, 200)}`);
    }
    return attempt;
  });
  if (res.resync !== undefined) {
    console.log(`偏移不符，服务器要求从 ${res.resync} 继续`);
    offset = res.resync;
    resumes += 1;
    continue;
  }
  uploads += 1;
  if (res.status === 200) {
    if (res.json?.sha256 !== sha256) {
      throw new Error(`服务器回算的 sha256 与本地不一致：${res.json?.sha256}`);
    }
    offset = size;
    break;
  }
  offset = Number(res.json.offset);
  if (process.stderr.isTTY) {
    const percent = ((offset / size) * 100).toFixed(1);
    process.stderr.write(`\r上传 ${percent}%（${offset}/${size}）`);
  }
}
// 进度只在终端里画；非交互调用（CI / PowerShell 重定向）时不要往 stderr 写字节，
// 否则 5.1 会把任意 stderr 输出包装成 NativeCommandError，父进程看起来像失败。
if (process.stderr.isTTY) process.stderr.write('\n');

const url = `${base}${session.url || `/${key}`}`;
const probe = await withRetry('可达性检查', async () => {
  const res = await call(url, { headers: { Range: 'bytes=0-0' } });
  if (res.status !== 206 && res.status !== 200) {
    throw new Error(`HTTP ${res.status}`);
  }
  return res;
});

const result = {
  ok: true,
  url,
  key,
  size,
  sha256,
  chunks,
  uploadedChunks: uploads,
  resumes,
  elapsedMs: Date.now() - started,
  reachable: probe.status,
};
if (asJson) console.log(JSON.stringify(result));
else {
  console.log(`下载地址  ${url}`);
  console.log(`SHA-256   ${sha256}`);
  console.log(`大小      ${(size / 1048576).toFixed(1)} MB，${chunks} 片，${(result.elapsedMs / 1000).toFixed(1)}s`);
  console.log(`可达性    HTTP ${probe.status}（Range 0-0）`);
}
