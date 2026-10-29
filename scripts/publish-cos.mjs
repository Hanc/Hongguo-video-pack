#!/usr/bin/env node
// Uploads release artifacts and latest.json to Tencent COS with a hand-rolled
// v5 signature so the release path needs no dependencies.
//
//   node scripts/publish-cos.mjs probe
//   node scripts/publish-cos.mjs push-windows <Setup.exe> --notes "..." 
//   node scripts/publish-cos.mjs push-android <apk> --notes "..."
//   node scripts/publish-cos.mjs release            # both, from dist/
//
// Credentials live in .local/cos.json (gitignored).
import { createHash, createHmac, randomUUID } from 'node:crypto';
import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs';
import { request } from 'node:https';
import { basename, join } from 'node:path';

const root = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const configPath = join(root, '.local', 'cos.json');
const prefix = 'updates';

function config() {
  if (!existsSync(configPath)) {
    throw new Error(`缺少 ${configPath}（需要 bucket / region / secretId / secretKey / publicBase）`);
  }
  return JSON.parse(readFileSync(configPath, 'utf8'));
}

function encodePath(pathname) {
  return pathname
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
}

function signed({ method, pathname, contentType, size, secretId, secretKey, bucket, region }) {
  const now = Math.floor(Date.now() / 1000);
  const keyTime = `${now};${now + 3600}`;
  // COS v5 derives the signing key as the HEX string of HMAC-SHA1, not raw bytes.
  const signKey = createHmac('sha1', secretKey).update(keyTime).digest('hex');
  const host = `${bucket}.cos.${region}.myqcloud.com`;
  const headerString = `host=${encodeURIComponent(host)}`;
  const httpString = `${method.toLowerCase()}\n${pathname}\n\n${headerString}\n`;
  const stringToSign = `sha1\n${keyTime}\n${createHash('sha1').update(httpString).digest('hex')}\n`;
  const signature = createHmac('sha1', signKey).update(stringToSign).digest('hex');
  const headers = {
    Host: host,
    Authorization:
      `q-sign-algorithm=sha1&q-ak=${secretId}&q-sign-time=${keyTime}` +
      `&q-key-time=${keyTime}&q-header-list=host&q-url-param-list=&q-signature=${signature}`,
  };
  if (contentType) headers['Content-Type'] = contentType;
  if (size !== undefined) headers['Content-Length'] = size;
  return { host, headers };
}

function send({ host, headers, method, pathname, body }) {
  return new Promise((resolve, reject) => {
    const req = request({ host, path: pathname, method, headers }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    req.setTimeout(180000, () => req.destroy(new Error('COS 请求超时')));
    if (body) {
      if (typeof body === 'string' || Buffer.isBuffer(body)) req.end(body);
      else body.pipe(req);
    } else {
      req.end();
    }
  });
}

async function upload(cfg, key, source, contentType) {
  const pathname = encodePath(`/${key}`);
  const isBuffer = Buffer.isBuffer(source);
  const size = isBuffer ? source.length : statSync(source).size;
  const { host, headers } = signed({
    method: 'PUT',
    pathname,
    contentType,
    size,
    secretId: cfg.secretId,
    secretKey: cfg.secretKey,
    bucket: cfg.bucket,
    region: cfg.region,
  });
  const started = Date.now();
  const res = await send({
    host,
    headers,
    method: 'PUT',
    pathname,
    body: isBuffer ? source : createReadStream(source),
  });
  if (res.status !== 200) {
    throw new Error(`上传 ${key} 失败：HTTP ${res.status} ${res.body.toString('utf8').slice(0, 300)}`);
  }
  return { key, size, ms: Date.now() - started, url: `${cfg.publicBase}/${encodePath(key)}` };
}

async function sha256Of(path) {
  const hash = createHash('sha256');
  await new Promise((resolve, reject) => {
    createReadStream(path)
      .on('data', (chunk) => hash.update(chunk))
      .on('end', resolve)
      .on('error', reject);
  });
  return hash.digest('hex');
}

function version() {
  const text = readFileSync(join(root, 'pubspec.yaml'), 'utf8');
  const line = /^version:\s*(\S+)\s*$/m.exec(text);
  if (!line) throw new Error('pubspec.yaml 缺少 version');
  const [name, build] = line[1].split('+');
  return { name, code: Number(build) };
}

function artifactName(platform, ver) {
  return platform === 'android'
    ? `Hongputao-Android-arm64-${ver.name}.apk`
    : `Hongputao-Windows-${ver.name}-Setup.exe`;
}

function remoteKey(platform, ver, file, sha256) {
  const suffix = sha256.slice(0, 8);
  const stamp = basename(file).replace(/\.(apk|exe)$/i, '');
  return `${prefix}/${platform}/${stamp}-${suffix}.${basename(file).split('.').pop()}`;
}

async function publish(platform, file, notes) {
  const cfg = config();
  const ver = version();
  if (!existsSync(file)) throw new Error(`找不到产物：${file}`);
  const sha256 = await sha256Of(file);
  const key = remoteKey(platform, ver, file, sha256);
  console.log(`上传 ${basename(file)} → ${key}`);
  const uploaded = await upload(
    cfg,
    key,
    file,
    platform === 'android' ? 'application/vnd.android.package-archive' : 'application/octet-stream',
  );
  console.log(`  ${(uploaded.size / 1048576).toFixed(1)} MB，${(uploaded.ms / 1000).toFixed(1)}s`);

  const manifest = {
    platform,
    version: ver.name,
    versionCode: ver.code,
    url: uploaded.url,
    size: uploaded.size,
    sha256,
    publishedAt: new Date().toISOString(),
    kind: platform === 'android' ? 'apk' : 'exe',
    notes,
    requestId: randomUUID(),
  };
  const body = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  const latestKey = `${prefix}/${platform}/latest.json`;
  const latest = await upload(cfg, latestKey, body, 'application/json; charset=utf-8');
  console.log(`  latest.json → ${latest.url}`);

  const probe = await fetchText(latest.url);
  if (probe.status !== 200) throw new Error(`回读 latest.json 失败：HTTP ${probe.status}`);
  const parsed = JSON.parse(probe.body);
  if (parsed.sha256 !== sha256) throw new Error('回读的 sha256 与本地不一致');
  console.log(`  ✓ 回读校验通过（${parsed.version} / ${parsed.versionCode}）`);
  return { manifest, latestUrl: latest.url };
}

function fetchText(url) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const req = request(
      { host: target.host, path: target.pathname + target.search, method: 'GET' },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
      },
    );
    req.on('error', reject);
    req.setTimeout(30000, () => req.destroy(new Error('回读超时')));
    req.end();
  });
}

async function probe() {
  const cfg = config();
  const key = `${prefix}/_probe.json`;
  const body = Buffer.from(JSON.stringify({ at: new Date().toISOString(), probe: true }));
  const uploaded = await upload(cfg, key, body, 'application/json');
  console.log(`写入探测对象：${uploaded.url}`);
  const read = await fetchText(uploaded.url);
  if (read.status !== 200) {
    throw new Error(`公有读未生效：HTTP ${read.status}（桶权限应为「公有读私有写」）`);
  }
  console.log(`公有读回读：HTTP 200，${read.body.length} 字节`);
}

const argv = process.argv.slice(2);
const command = argv[0];
const notes = (() => {
  const at = argv.indexOf('--notes');
  return at >= 0 ? argv[at + 1] : '常规更新';
})();

try {
  if (command === 'probe') {
    await probe();
  } else if (command === 'push-android' || command === 'push-windows') {
    const platform = command === 'push-android' ? 'android' : 'windows';
    await publish(platform, argv[1], notes);
  } else if (command === 'release') {
    const ver = version();
    for (const platform of ['windows', 'android']) {
      const file = join(root, 'dist', artifactName(platform, ver));
      await publish(platform, file, notes);
    }
  } else {
    console.log('用法：probe | push-android <apk> | push-windows <exe> | release  [--notes "说明"]');
    process.exit(2);
  }
} catch (error) {
  console.error(`失败：${error.message}`);
  process.exit(1);
}
