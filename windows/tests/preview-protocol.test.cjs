const { test } = require('node:test');
const assert = require('node:assert/strict');
const { byteRange, mediaHandler } = require('../electron/preview-protocol.cjs');
test('single closed, open, and suffix ranges; reject invalid or multiple ranges', () => {
  assert.deepEqual(byteRange(null, 100), { start: 0, end: 99, partial: false });
  assert.deepEqual(byteRange('bytes=7-20', 100), { start: 7, end: 20, partial: true });
  assert.deepEqual(byteRange('bytes=90-', 100), { start: 90, end: 99, partial: true });
  assert.deepEqual(byteRange('bytes=-10', 100), { start: 90, end: 99, partial: true });
  assert.deepEqual(byteRange('bytes=90-200', 100), { start: 90, end: 99, partial: true });
  for (const value of [
    'bytes=100-',
    'bytes=-0',
    'bytes=8-4',
    'bytes=1-2,4-5',
    'bytes=-',
    'bytes=99999999999999999999-',
  ])
    assert.equal(byteRange(value, 100), null);
});
test('private preview streams only requested bytes with bounded reads', async () => {
  const content = Buffer.alloc(3 * 1024 * 1024 + 27);
  for (let i = 0; i < content.length; i++) content[i] = i % 251;
  const calls = [],
    token = 'x'.repeat(43),
    handler = mediaHandler(async (method, p) => {
      calls.push([method, p]);
      if (method === 'galleryMediaInfo') return { size: content.length, mime: 'video/mp4' };
      const data = content.subarray(p.offset, p.offset + p.length);
      return { data: data.toString('base64') };
    });
  const response = await handler(
    new Request('phosphor-media://preview/' + token, {
      headers: { Range: 'bytes=123-' + (content.length - 321) },
    }),
  );
  assert.equal(response.status, 206);
  assert.equal(response.headers.get('Accept-Ranges'), 'bytes');
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('Content-Length'), String(content.length - 443));
  assert.deepEqual(
    Buffer.from(await response.arrayBuffer()),
    content.subarray(123, content.length - 320),
  );
  assert.ok(
    calls.filter(([m]) => m === 'galleryMediaRead').every(([, p]) => p.length <= 1024 * 1024),
  );
});
test('HEAD, expired, malicious paths, and unsatisfiable ranges', async () => {
  let reads = 0;
  const token = 'x'.repeat(43),
    handler = mediaHandler(async (method) => {
      if (method === 'galleryMediaRead') reads++;
      return { size: 100, mime: 'image/jpeg' };
    });
  assert.equal(
    (await handler(new Request('phosphor-media://preview/' + token, { method: 'HEAD' }))).body,
    null,
  );
  assert.equal(reads, 0);
  assert.equal((await handler(new Request('phosphor-media://other/' + token))).status, 404);
  assert.equal(
    (await handler(new Request('phosphor-media://preview/' + token + '?path=C:/Windows'))).status,
    404,
  );
  assert.equal(
    (
      await handler(
        new Request('phosphor-media://preview/' + token, { headers: { Range: 'bytes=101-' } }),
      )
    ).status,
    416,
  );
  assert.equal(
    (
      await mediaHandler(async () => {
        throw Error('locked');
      })(new Request('phosphor-media://preview/' + token))
    ).status,
    404,
  );
});
test('backup and file previews use separate RPC scopes', async () => {
  for (const [host, prefix] of [
    ['preview', 'gallery'],
    ['file-preview', 'file'],
  ]) {
    const calls = [],
      handler = mediaHandler(async (method) => {
        calls.push(method);
        return method.endsWith('Info')
          ? { size: 3, mime: 'image/jpeg' }
          : { data: Buffer.from('abc').toString('base64') };
      });
    const response = await handler(new Request('phosphor-media://' + host + '/' + 'x'.repeat(43)));
    assert.equal(await response.text(), 'abc');
    assert.deepEqual(calls, [prefix + 'MediaInfo', prefix + 'MediaRead']);
  }
});

test('file PDF streaming exposes range headers only to trusted renderer origins', async () => {
  const token = 'p'.repeat(43),
    handler = mediaHandler(async (method) =>
      method === 'fileMediaInfo'
        ? { size: 1024 * 1024 * 12, mime: 'application/pdf' }
        : { data: Buffer.from('%PDF-').toString('base64') },
    );
  for (const origin of ['null', 'http://127.0.0.1:5173', 'https://untrusted.example']) {
    const response = await handler(
      new Request('phosphor-media://file-preview/' + token, {
        method: 'HEAD',
        headers: { Origin: origin, Range: 'bytes=0-4' },
      }),
    );
    assert.equal(response.status, 206);
    assert.equal(response.headers.get('Content-Type'), 'application/pdf');
    assert.equal(response.headers.get('Content-Range'), 'bytes 0-4/12582912');
    assert.equal(
      response.headers.get('Access-Control-Allow-Origin'),
      origin === 'https://untrusted.example' ? null : origin,
    );
    assert.match(response.headers.get('Access-Control-Expose-Headers'), /Content-Range/);
  }
});
