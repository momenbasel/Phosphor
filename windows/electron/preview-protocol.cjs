// Range streaming keeps large videos out of renderer IPC and temporary files.
function byteRange(value, size) {
  if (!value) return { start: 0, end: Math.max(0, size - 1), partial: false };
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || (!match[1] && !match[2]) || !size) return null;
  let start, end;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : size - 1;
  }
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(end) ||
    start < 0 ||
    end < start ||
    start >= size
  )
    return null;
  return { start, end: Math.min(end, size - 1), partial: true };
}
function mediaHandler(rpc) {
  return async (request) => {
    const url = new URL(request.url),
      token = url.pathname.slice(1);
    const hosts = {
        preview: ['galleryMediaInfo', 'galleryMediaRead'],
        'file-preview': ['fileMediaInfo', 'fileMediaRead'],
      },
      methods = hosts[url.hostname];
    if (!methods || url.search || !/^[-_A-Za-z0-9]{43}$/.test(token))
      return new Response('Unknown preview', { status: 404 });
    if (!['GET', 'HEAD'].includes(request.method))
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    let info;
    try {
      info = await rpc(methods[0], { token });
    } catch {
      return new Response('Preview expired or locked', { status: 404 });
    }
    const size = Number(info.size);
    if (!Number.isSafeInteger(size) || size < 0)
      return new Response('Invalid preview size', { status: 500 });
    const range = byteRange(request.headers.get('Range'), size);
    if (!range)
      return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
    const length = size ? range.end - range.start + 1 : 0,
      headers = {
        'Content-Type': info.mime || 'application/octet-stream',
        'Content-Length': String(length),
        'Accept-Ranges': 'bytes',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      };
    // The packaged renderer has the opaque file:// origin. Other origins do
    // not receive CORS access; preview URLs also require unguessable tokens.
    const origin = request.headers.get('Origin');
    if (origin === 'null' || origin === 'http://127.0.0.1:5173')
      headers['Access-Control-Allow-Origin'] = origin;
    headers['Access-Control-Expose-Headers'] = 'Content-Length, Content-Range, Accept-Ranges';
    headers.Vary = 'Origin';
    if (range.partial) headers['Content-Range'] = `bytes ${range.start}-${range.end}/${size}`;
    let offset = range.start,
      stopped = false;
    const stream =
      request.method === 'HEAD'
        ? null
        : new ReadableStream({
            async pull(controller) {
              if (stopped) return;
              if (request.signal.aborted) {
                stopped = true;
                controller.close();
                return;
              }
              if (!size || offset > range.end) {
                stopped = true;
                controller.close();
                return;
              }
              try {
                const result = await rpc(methods[1], {
                  token,
                  offset,
                  length: Math.min(1024 * 1024, range.end - offset + 1),
                });
                if (stopped) return;
                const chunk = Buffer.from(result.data, 'base64');
                if (!chunk.length || chunk.length > range.end - offset + 1)
                  throw new Error('Invalid media chunk');
                offset += chunk.length;
                controller.enqueue(chunk);
                if (offset > range.end) {
                  stopped = true;
                  controller.close();
                }
              } catch (error) {
                stopped = true;
                controller.error(error);
              }
            },
            cancel() {
              stopped = true;
            },
          });
    return new Response(stream, { status: range.partial ? 206 : 200, headers });
  };
}
module.exports = { byteRange, mediaHandler };
