#!/usr/bin/env node
// 红葡萄分发服务（服务器端）· 零依赖，Node 18+
//
//   DL_TOKEN=xxxx node dl-server.mjs --root /var/www/hongguo/dl --port 8099 --host 127.0.0.1
//
// 上传协议（分片 + 断点续传，与 push-artifact.mjs 对齐）：
//   POST /upload/session                {key,size,sha256}  → 201 {sessionId,offset}；已存在则 200 带 offset
//   PUT  /upload/session/<id>  Content-Range: bytes a-b/total
//                                        → 202 {offset} 中间态；200 {ok,url,size,sha256} 完成态
// 下载：GET/HEAD 静态文件，支持 Range(206)、ETag/304；/.json 强制 no-store。
//
// 状态码约定：401 无/错令牌 · 400 路径穿越或哈希不符 · 403 根目录 · 413 超大包 ·
//             409 续传偏移不符 · 415 非法后缀 · 429 新会话被限流。
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmdirSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join, resolve, sep } from 'node:path';

function arg(name, fallback) {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 ? process.argv[at + 1] : fallback;
}

const root = resolve(arg('root', './dl'));
const token = arg('token', process.env.DL_TOKEN || '');
const port = Number(arg('port', process.env.DL_PORT || 8099));
const host = arg('host', '0.0.0.0');
const maxBytes = Number(arg('max-mb', 400)) * 1024 * 1024;
const keep = Number(arg('keep', 5));
const rate = Number(arg('rate', 20));
const allowed = new Set(['.apk', '.exe', '.zip', '.json']);
const types = {
  '.apk': 'application/vnd.android.package-archive',
  '.exe': 'application/octet-stream',
  '.zip': 'application/zip',
  '.json': 'application/json; charset=utf-8',
};

if (!token) {
  console.error('缺少 --token（或环境变量 DL_TOKEN）：没有令牌的上传接口等于把写入权限公开。');
  process.exit(2);
}
mkdirSync(root, { recursive: true });

/** 会话内存表；磁盘上用 <partial>.meta 兜住重启后的续传。 */
const sessions = new Map();
const creations = [];

function sha256OfFile(path) {
  return new Promise((resolveHash, reject) => {
    const digest = createHash('sha256');
    createReadStream(path)
      .on('data', (chunk) => digest.update(chunk))
      .on('end', () => resolveHash(digest.digest('hex')))
      .on('error', reject);
  });
}

/** URL 路径 → root 内真实路径。返回 {error,message} 表示要拒。 */
function guard(urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath);
  } catch {
    return { error: 400, message: '路径编码不合法' };
  }
  if (decoded.includes('\0')) return { error: 400, message: '路径不合法' };
  const parts = decoded.split('/').filter((part) => part.length > 0);
  if (parts.length === 0) return { error: 403, message: '不提供目录列表' };
  if (parts.some((part) => part === '..' || part === '.' || part.startsWith('.'))) {
    return { error: 400, message: '路径穿越被拒绝' };
  }
  const target = resolve(join(root, ...parts));
  if (!target.startsWith(root + sep)) return { error: 400, message: '路径越界' };
  const ext = target.slice(target.lastIndexOf('.')).toLowerCase();
  if (!allowed.has(ext)) return { error: 415, message: `不接受的文件类型：${ext}` };
  return { target, parts };
}

function send(res, status, payload, extraHeaders = {}) {
  const body = typeof payload === 'string' ? payload : JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
    ...extraHeaders,
  });
  res.end(body);
}

function drain(req) {
  req.resume();
}

function metaPath(partial) {
  return `${partial}.meta`;
}

function saveMeta(session) {
  writeFileSync(
    session.metaPath,
    JSON.stringify({ key: session.key, size: session.size, sha256: session.sha256, offset: session.offset }),
  );
}

function prune(dir, protect) {
  if (keep <= 0 || !existsSync(dir)) return [];
  const candidates = readdirSync(dir)
    .map((name) => join(dir, name))
    .filter((path) => {
      const base = path.slice(path.lastIndexOf(sep) + 1);
      if (base.endsWith('.part') || base.endsWith('.meta')) return false;
      if (base === 'latest.json' || base.endsWith('.json')) return false;
      return existsSync(path) && statSync(path).isFile();
    })
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  const keepSet = new Set(candidates.slice(0, keep));
  // mtime 可能精确到毫秒级并列，导致刚上传的包被挤出保留集合；这里强制把它换进来。
  if (protect && !keepSet.has(protect) && keepSet.size > 0) {
    const victim = [...keepSet].pop();
    keepSet.delete(victim);
    keepSet.add(protect);
  } else if (protect) {
    keepSet.add(protect);
  }
  const removed = [];
  for (const path of candidates) {
    if (keepSet.has(path)) continue;
    try {
      unlinkSync(path);
      removed.push(path.slice(path.lastIndexOf(sep) + 1));
    } catch {}
  }
  return removed;
}

/** 清掉 24 小时前的未完成分片，避免崩溃/放弃的会话在磁盘上堆积。 */
function sweepStale(maxAgeMs = 24 * 3600 * 1000) {
  const cutoff = Date.now() - maxAgeMs;
  const removed = [];
  const walk = (dir) => {
    if (!existsSync(dir)) return;
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      let stat;
      try {
        stat = statSync(path);
      } catch {
        continue;
      }
      if (stat.isDirectory()) {
        walk(path);
        continue;
      }
      if (!name.endsWith('.part') && !name.endsWith('.part.meta')) continue;
      if (stat.mtimeMs > cutoff) continue;
      try {
        unlinkSync(path);
        removed.push(name);
      } catch {}
    }
  };
  walk(root);
  if (removed.length > 0) console.log(`清理过期分片 ${removed.length} 个`);
  return removed;
}

async function createSession(req, res) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
    if (Buffer.concat(chunks).length > 65536) {
      send(res, 413, { ok: false, error: '会话参数过大' });
      return;
    }
  }
  let body;
  try {
    body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    send(res, 400, { ok: false, error: '请求体不是 JSON' });
    return;
  }
  const key = String(body.key || '');
  const size = Number(body.size || 0);
  const sha256 = String(body.sha256 || '').toLowerCase();
  const guarded = guard(`/${key}`);
  if (guarded.error) {
    send(res, guarded.error, { ok: false, error: guarded.message });
    return;
  }
  if (!/^[0-9a-f]{64}$/.test(sha256)) {
    send(res, 400, { ok: false, error: 'sha256 必须是 64 位十六进制' });
    return;
  }
  if (!Number.isFinite(size) || size <= 0) {
    send(res, 400, { ok: false, error: 'size 必须是正整数' });
    return;
  }
  if (size > maxBytes) {
    send(res, 413, { ok: false, error: `超过上限 ${maxBytes / 1048576} MB` });
    return;
  }

  const target = guarded.target;
  const partial = `${target}.part`;
  const meta = metaPath(partial);

  // 已有同 key 的会话或未完成的分片 → 直接续传，不计入限流。
  const existing = [...sessions.values()].find((item) => item.key === key && item.sha256 === sha256);
  if (existing) {
    send(res, 200, { ok: true, sessionId: existing.id, offset: existing.offset, resumed: true });
    return;
  }

  const now = Date.now();
  while (creations.length > 0 && now - creations[0] > 60000) creations.shift();
  if (creations.length >= rate) {
    send(res, 429, { ok: false, error: `新建会话过快（每分钟 ${rate} 个），请稍后重试` }, { 'retry-after': '60' });
    return;
  }
  creations.push(now);

  let offset = 0;
  let hash = createHash('sha256');
  if (existsSync(meta) && existsSync(partial)) {
    try {
      const saved = JSON.parse(readFileSync(meta, 'utf8'));
      if (saved.key === key && Number(saved.size) === size && saved.sha256 === sha256) {
        offset = statSync(partial).size;
        if (offset > 0) hash = createHash('sha256');
        if (offset > 0) {
          await new Promise((resolveHash, reject) => {
            createReadStream(partial)
              .on('data', (chunk) => hash.update(chunk))
              .on('end', resolveHash)
              .on('error', reject);
          });
        }
      }
    } catch {}
  }
  if (offset === 0) {
    mkdirSync(dirname(partial), { recursive: true });
    writeFileSync(partial, Buffer.alloc(0));
    hash = createHash('sha256');
  }
  const id = randomUUID().replace(/-/g, '');
  const session = { id, key, target, partial, metaPath: meta, size, sha256, offset, hash, createdAt: now };
  sessions.set(id, session);
  saveMeta(session);

  if (offset === size) {
    await finalize(res, session, offset);
    return;
  }
  send(res, 201, { ok: true, sessionId: id, offset, resumed: offset > 0 });
}

async function finalize(res, session, offset) {
  const actual = session.hash.digest('hex');
  if (actual !== session.sha256) {
    try {
      unlinkSync(session.partial);
      unlinkSync(session.metaPath);
    } catch {}
    sessions.delete(session.id);
    send(res, 400, { ok: false, error: 'sha256 与声明不一致，已丢弃', declared: session.sha256, actual });
    return;
  }
  mkdirSync(dirname(session.target), { recursive: true });
  renameSync(session.partial, session.target);
  try {
    unlinkSync(session.metaPath);
  } catch {}
  sessions.delete(session.id);
  const removed = prune(dirname(session.target), session.target);
  const urlPath = '/' + session.key.split('/').map(encodeURIComponent).join('/');
  send(res, 200, { ok: true, key: session.key, url: urlPath, size: offset, sha256: actual, pruned: removed });
}

function receiveChunk(req, res, session) {
  const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(String(req.headers['content-range'] || '').trim());
  if (!range) {
    drain(req);
    send(res, 400, { ok: false, error: '缺少或非法的 Content-Range（形如 bytes 0-1023/2048）' });
    return;
  }
  const start = Number(range[1]);
  const end = Number(range[2]);
  const total = Number(range[3]);
  if (total !== session.size) {
    drain(req);
    send(res, 400, { ok: false, error: 'Content-Range 的总长与会话不符', expected: session.size, got: total });
    return;
  }
  if (start !== session.offset) {
    drain(req);
    send(res, 409, { ok: false, error: '续传偏移不符', offset: session.offset });
    return;
  }
  if (end < start || end >= session.size) {
    drain(req);
    send(res, 413, { ok: false, error: '分片超出文件范围', size: session.size });
    return;
  }
  const declared = Number(req.headers['content-length'] || 0);
  if (declared !== end - start + 1) {
    drain(req);
    send(res, 400, { ok: false, error: 'Content-Length 与 Content-Range 不一致' });
    return;
  }

  const sink = createWriteStream(session.partial, { flags: 'a' });
  let received = 0;
  let failed = false;
  req.on('data', (chunk) => {
    received += chunk.length;
    if (received > declared && !failed) {
      failed = true;
      sink.destroy();
      send(res, 413, { ok: false, error: '分片超出声明长度' });
      req.destroy();
      return;
    }
    session.hash.update(chunk);
    sink.write(chunk);
  });
  req.on('end', async () => {
    if (failed) return;
    if (received !== declared) {
      sink.end();
      send(res, 400, { ok: false, error: '分片未收全', expected: declared, received });
      return;
    }
    session.offset = end + 1;
    saveMeta(session);
    sink.end(async () => {
      if (session.offset >= session.size) {
        await finalize(res, session, session.offset);
        return;
      }
      send(res, 202, { ok: true, offset: session.offset });
    });
  });
  req.on('error', () => {
    try {
      sink.destroy();
    } catch {}
  });
}

function etagFor(path, stat) {
  return `"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}"`;
}

function serve(req, res, target) {
  if (!existsSync(target) || !statSync(target).isFile()) {
    send(res, 404, { ok: false, error: '文件不存在' });
    return;
  }
  const stat = statSync(target);
  const size = stat.size;
  const ext = target.slice(target.lastIndexOf('.')).toLowerCase();
  const etag = etagFor(target, stat);
  const headers = {
    'content-type': types[ext] || 'application/octet-stream',
    'accept-ranges': 'bytes',
    'etag': etag,
    'cache-control':
      ext === '.json'
        ? 'no-store'
        : /[-.][0-9a-f]{8}\.(apk|exe|zip)$/i.test(target)
          ? 'public, max-age=31536000, immutable'
          : 'public, max-age=3600',
  };
  const inm = String(req.headers['if-none-match'] || '');
  if (inm && inm.split(',').map((item) => item.trim()).includes(etag)) {
    res.writeHead(304, headers);
    res.end();
    return;
  }
  const range = req.headers.range;
  if (range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(String(range).trim());
    if (!match) {
      send(res, 416, { ok: false, error: 'Range 不合法' });
      return;
    }
    const start = match[1] === '' ? size - Number(match[2]) : Number(match[1]);
    const end = match[2] === '' || match[1] === '' ? size - 1 : Number(match[2]);
    if (start < 0 || end >= size || start > end) {
      res.writeHead(416, { ...headers, 'content-range': `bytes */${size}` });
      res.end();
      return;
    }
    res.writeHead(206, { ...headers, 'content-range': `bytes ${start}-${end}/${size}`, 'content-length': end - start + 1 });
    if (req.method === 'HEAD') {
      res.end();
      return;
    }
    createReadStream(target, { start, end }).pipe(res);
    return;
  }
  res.writeHead(200, { ...headers, 'content-length': size });
  if (req.method === 'HEAD') {
    res.end();
    return;
  }
  createReadStream(target).pipe(res);
}

function handleRequest(req, res) {
  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  if (url.pathname === '/health') {
    send(res, 200, { ok: true, root, sessions: sessions.size, keep, rate });
    return;
  }
  const authed = req.headers.authorization === `Bearer ${token}`;

  if (req.method === 'POST' && url.pathname === '/upload/session') {
    if (!authed) {
      drain(req);
      send(res, 401, { ok: false, error: '令牌不正确' });
      return;
    }
    createSession(req, res).catch((error) => send(res, 500, { ok: false, error: error.message }));
    return;
  }
  if (req.method === 'PUT' && url.pathname.startsWith('/upload/session/')) {
    if (!authed) {
      drain(req);
      send(res, 401, { ok: false, error: '令牌不正确' });
      return;
    }
    const id = url.pathname.slice('/upload/session/'.length);
    const session = sessions.get(id);
    if (!session) {
      drain(req);
      send(res, 404, { ok: false, error: '会话不存在或已过期，请重新创建' });
      return;
    }
    receiveChunk(req, res, session);
    return;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    drain(req);
    send(res, 405, { ok: false, error: '只支持 GET/HEAD/POST/PUT' });
    return;
  }
  const guarded = guard(url.pathname);
  if (guarded.error) {
    send(res, guarded.error, { ok: false, error: guarded.message });
    return;
  }
  serve(req, res, guarded.target);
}

const server = createServer((req, res) => {
  try {
    handleRequest(req, res);
  } catch (error) {
    // 单个请求的异常绝不能带走整个分发服务：记录并回 500。
    console.error(`[${new Date().toISOString()}] 处理 ${req.method} ${req.url} 失败：${error && error.stack ? error.stack : error}`);
    if (!res.headersSent) send(res, 500, { ok: false, error: '服务内部错误' });
    else res.destroy();
  }
});

// 客户端半途断开（手机切网、curl 超时）是常态，不是错误，直接丢连接即可。
server.on('clientError', (error, socket) => {
  if (socket.writable) socket.destroy();
  console.error(`[${new Date().toISOString()}] 客户端连接异常：${error && error.message ? error.message : error}`);
});

// 兜底：任何漏网的异步异常都只记录，不让进程退出（否则监听口会消失、外部表现为空回复）。
process.on('uncaughtException', (error) => {
  console.error(`[${new Date().toISOString()}] 未捕获异常：${error && error.stack ? error.stack : error}`);
});
process.on('unhandledRejection', (reason) => {
  console.error(`[${new Date().toISOString()}] 未处理的 Promise 拒绝：${reason && reason.stack ? reason.stack : reason}`);
});

server.listen(port, host, () => {
  console.log(`分发服务已启动 http://${host}:${port}  根目录 ${root}  保留 ${keep} 个/目录  限流 ${rate} 会话/分钟`);
  // 崩溃或放弃的上传会在磁盘留下 .part：启动时扫一次，之后每 30 分钟一次（只清 24h 前的）。
  sweepStale();
  setInterval(() => sweepStale(), 30 * 60 * 1000).unref();
});
