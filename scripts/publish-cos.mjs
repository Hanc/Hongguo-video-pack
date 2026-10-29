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
import { copyFileSync, createReadStream, existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { request } from 'node:https';
import { basename, dirname, join } from 'node:path';

const root = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const configPath = join(root, '.local', 'cos.json');
const prefix = 'updates';

function config() {
  if (!existsSync(configPath)) {
    throw new Error(`缺少 ${configPath}（需要 bucket / region / secretId / secretKey）`);
  }
  const cfg = JSON.parse(readFileSync(configPath, 'utf8'));
  // 腾讯云禁止用 COS 默认域名分发 APK/IPA，所以安装包要挂在已备案的自定义域名上；
  // latest.json 仍留在默认域名，已装好的客户端才知道去哪里读清单。
  cfg.packageBase = (process.env.HONGGUO_PACKAGE_BASE || cfg.packageBase || '').replace(/\/+$/, '');
  return cfg;
}

function packageUrlFor(cfg, key, fallback) {
  return cfg.packageBase ? `${cfg.packageBase}/${encodePath(key)}` : fallback;
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

// 把安装包推到自建分发服务（server/dl-server.mjs 的 PUT /upload/<key> 接口）。
// 直连自己的域名，不经过 COS；令牌只从环境变量取，避免出现在命令历史里。
function uploadToServer(serverBase, token, key, source, contentType) {
  return new Promise((resolve, reject) => {
    const target = new URL(`${serverBase}/upload/${encodePath(key)}`);
    const agent = target.protocol === 'http:' ? httpRequest : request;
    const size = statSync(source).size;
    const started = Date.now();
    const req = agent(
      {
        host: target.hostname,
        port: target.port || undefined,
        path: target.pathname + target.search,
        method: 'PUT',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': contentType,
          'Content-Length': size,
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          if (res.statusCode !== 201 && res.statusCode !== 200) {
            reject(new Error(`上传到 ${target.host} 失败：HTTP ${res.statusCode} ${text.slice(0, 200)}`));
            return;
          }
          let parsed = {};
          try {
            parsed = JSON.parse(text);
          } catch {
            reject(new Error(`上传接口返回的不是 JSON：${text.slice(0, 120)}`));
            return;
          }
          resolve({ size, ms: Date.now() - started, remoteSha256: parsed.sha256, url: `${serverBase}/${encodePath(key)}` });
        });
      },
    );
    req.on('error', (error) => reject(new Error(`连接 ${target.host} 失败：${error.message}`)));
    req.setTimeout(600000, () => req.destroy(new Error('上传到自建服务超时')));
    createReadStream(source).pipe(req);
  });
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
  // 去掉可能的旧哈希后缀，避免把已经带哈希的文件再叠一次（stage 目录里的文件就是这种）。
  const stamp = basename(file)
    .replace(/\.(apk|exe)$/i, '')
    .replace(/-[0-9a-f]{8}$/i, '');
  return `${prefix}/${platform}/${stamp}-${suffix}.${basename(file).split('.').pop()}`;
}

async function publish(platform, file, notes, opts = {}) {
  const cfg = config();
  const serverBase = (opts.serverBase || '').replace(/\/+$/, '');
  if (opts.packageBase) cfg.packageBase = opts.packageBase.replace(/\/+$/, '');
  // 自建分发服务同时就是安装包的下载源，优先级高于 COS 自定义域名。
  if (serverBase) cfg.packageBase = serverBase;
  const ver = version();
  if (!existsSync(file)) throw new Error(`找不到产物：${file}`);
  const sha256 = await sha256Of(file);
  const key = remoteKey(platform, ver, file, sha256);
  const contentType =
    platform === 'android' ? 'application/vnd.android.package-archive' : 'application/octet-stream';
  let uploaded;
  if (serverBase && !opts.skipUpload) {
    if (!opts.uploadToken) {
      throw new Error('缺少上传令牌：请设置环境变量 HONGGUO_UPLOAD_TOKEN（服务端 --token 的值）');
    }
    console.log(`上传 ${basename(file)} → ${serverBase}/${key}`);
    uploaded = await uploadToServer(serverBase, opts.uploadToken, key, file, contentType);
    if (uploaded.remoteSha256 && uploaded.remoteSha256 !== sha256) {
      throw new Error(`服务器回算的 sha256 与本地不一致（${uploaded.remoteSha256.slice(0, 8)}…），已中止`);
    }
    console.log(`  ${(uploaded.size / 1048576).toFixed(1)} MB，${(uploaded.ms / 1000).toFixed(1)}s`);
  } else if (opts.skipUpload) {
    // 安装包已经由用户自己传到服务器了，这里只负责确认可达并改写清单。
    console.log(`跳过上传：${key}`);
    uploaded = {
      size: statSync(file).size,
      ms: 0,
      url: serverBase
        ? `${serverBase}/${encodePath(key)}`
        : `https://${cfg.bucket}.cos.${cfg.region}.myqcloud.com/${encodePath(key)}`,
    };
  } else {
    console.log(`上传 ${basename(file)} → ${key}`);
    uploaded = await upload(cfg, key, file, contentType);
    console.log(`  ${(uploaded.size / 1048576).toFixed(1)} MB，${(uploaded.ms / 1000).toFixed(1)}s`);
  }

  const manifest = {
    platform,
    version: ver.name,
    versionCode: ver.code,
    url: opts.packageUrl || packageUrlFor(cfg, key, uploaded.url),
    size: uploaded.size,
    sha256,
    publishedAt: new Date().toISOString(),
    kind: platform === 'android' ? 'apk' : 'exe',
    notes,
    requestId: randomUUID(),
  };
  // 先确认这个地址真能被匿名 GET 下来再写清单：COS 对受限安装包的 HEAD 仍回 200，
  // 只堵 GET，所以必须发一次真实的分段 GET。
  const reachable = await checkPackage(manifest.url);
  if (reachable.status === 403 && reachable.body.includes('DownloadForbidden')) {
    throw new Error(
      `${manifest.url} 被 COS 拒绝：默认域名不能分发 APK/IPA。` +
        '请在 .local/cos.json 里配置 packageBase（已备案的自定义域名）后重试。',
    );
  }
  if (reachable.status !== 200 && reachable.status !== 206) {
    throw new Error(`安装包地址不可下载：HTTP ${reachable.status}`);
  }
  console.log(`  ✓ 安装包地址可匿名下载（${manifest.url.split('/')[2]}）`);
  if (opts.noManifest) {
    console.log('  --no-manifest：跳过写 latest.json（本次只演练上传与可达性）');
    return { manifest, latestUrl: null };
  }
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

function agentFor(target) {
  return target.protocol === 'http:' ? httpRequest : request;
}

function checkPackage(url, hops = 0) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const req = agentFor(target)(
      {
        host: target.hostname,
        port: target.port || undefined,
        path: target.pathname + target.search,
        method: 'GET',
        headers: { Range: 'bytes=0-0' },
      },
      (res) => {
        // GitHub Release 的资产地址会 302 到对象存储，必须跟到最终响应再判定，
        // 否则会把「重定向成功」当成「不可下载」。
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && hops < 5) {
          res.resume();
          resolve(checkPackage(new URL(res.headers.location, url).toString(), hops + 1));
          return;
        }
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () =>
          resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }),
        );
      },
    );
    req.on('error', reject);
    req.setTimeout(30000, () => req.destroy(new Error('安装包可下载性检查超时')));
    req.end();
  });
}

function fetchText(url) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const req = agentFor(target)(
      { host: target.hostname, port: target.port || undefined, path: target.pathname + target.search, method: 'GET' },
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

async function stage() {
  const ver = version();
  const out = join(root, 'dist', 'remote');
  const staged = [];
  for (const platform of ['windows', 'android']) {
    const file = join(root, 'dist', artifactName(platform, ver));
    if (!existsSync(file)) continue;
    const sha256 = await sha256Of(file);
    const key = remoteKey(platform, ver, file, sha256);
    const target = join(out, key.split('/').join('\\'));
    mkdirSync(dirname(target), { recursive: true });
    copyFileSync(file, target);
    staged.push({ key, target, bytes: statSync(file).size });
  }
  if (staged.length === 0) throw new Error(`dist/ 里没有 ${ver.name} 的产物，先跑 dev.ps1 dist`);
  for (const item of staged) {
    console.log(`${(item.bytes / 1048576).toFixed(1)} MB  ${item.key}`);
  }
  console.log(`\n已复制到 ${out}\\ ，按上面的相对路径上传到你的服务器，保持路径一致。`);
  console.log('传完后用 HONGGUO_PACKAGE_BASE=https://你的域名 node scripts/publish-cos.mjs push-android … --skip-upload 改写清单（脚本会先验证地址真能下载）。');
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
const packageBase = (() => {
  const at = argv.indexOf('--package-base');
  return at >= 0 ? argv[at + 1] : undefined;
})();
// 完整下载地址（GitHub Release 之类的扁平路径），优先级高于 --package-base。
const packageUrl = (() => {
  const at = argv.indexOf('--package-url');
  return at >= 0 ? argv[at + 1] : undefined;
})();
const skipUpload = argv.includes('--skip-upload');
const noManifest = argv.includes('--no-manifest');
const serverBase = (() => {
  const at = argv.indexOf('--server-base');
  return at >= 0 ? argv[at + 1] : process.env.HONGGUO_SERVER_BASE || undefined;
})();
const uploadToken = process.env.HONGGUO_UPLOAD_TOKEN;

const options = { packageBase, packageUrl, skipUpload, noManifest, serverBase, uploadToken };

try {
  if (command === 'probe') {
    await probe();
  } else if (command === 'stage') {
    await stage();
  } else if (command === 'push-android' || command === 'push-windows') {
    const platform = command === 'push-android' ? 'android' : 'windows';
    await publish(platform, argv[1], notes, options);
  } else if (command === 'release') {
    const ver = version();
    for (const platform of ['windows', 'android']) {
      const file = join(root, 'dist', artifactName(platform, ver));
      await publish(platform, file, notes, options);
    }
  } else {
    console.log(
      '用法：probe | stage | push-android <apk> | push-windows <exe> | release' +
        '  [--notes "说明"] [--package-base https://域名] [--package-url https://完整地址]' +
        '  [--server-base https://自己的服务器] [--skip-upload] [--no-manifest]\n' +
        '上传令牌用环境变量 HONGGUO_UPLOAD_TOKEN 传入。',
    );
    process.exit(2);
  }
} catch (error) {
  console.error(`失败：${error.message}`);
  process.exit(1);
}
