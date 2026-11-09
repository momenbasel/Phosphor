const { test } = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs'),
  path = require('node:path');
const { buildSync } = require('esbuild'),
  { pathToFileURL } = require('node:url');
const target = path.resolve(__dirname, '../test-output/pdf-range-test.mjs');
fs.mkdirSync(path.dirname(target), { recursive: true });
buildSync({
  entryPoints: [path.resolve(__dirname, '../src/pdf_range.ts')],
  outfile: target,
  bundle: true,
  platform: 'node',
  format: 'esm',
  packages: 'external',
  alias: { 'pdfjs-dist': 'pdfjs-dist/legacy/build/pdf.mjs' },
  logLevel: 'silent',
});

function pdfFixture() {
  const chunks = [Buffer.from('%PDF-1.7\n')],
    offsets = [0];
  let length = chunks[0].length;
  const add = (id, body) => {
    offsets[id] = length;
    const part = Buffer.from(`${id} 0 obj\n${body}\nendobj\n`);
    chunks.push(part);
    length += part.length;
  };
  add(1, '<< /Type /Catalog /Pages 2 0 R >>');
  add(2, '<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>');
  for (let page = 3; page <= 4; page++)
    add(
      page,
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 7 0 R >> >> /Contents ${page + 2} 0 R >>`,
    );
  for (let content = 5; content <= 6; content++) {
    const text = `BT /F1 12 Tf 20 50 Td (${content === 5 ? 'First' : 'Second'} Phosphor fixture page) Tj ET`;
    add(content, `<< /Length ${text.length} >>\nstream\n${text}\nendstream`);
  }
  add(7, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  // An unreferenced 10-MiB stream makes the PDF exceed the former preview cap,
  // without requiring the parser to download that stream to display its pages.
  const padding = ' '.repeat(10 * 1024 * 1024);
  add(8, `<< /Length ${padding.length} >>\nstream\n${padding}\nendstream`);
  const xref = length;
  chunks.push(
    Buffer.from(
      'xref\n0 9\n0000000000 65535 f \n' +
        offsets
          .slice(1)
          .map((offset) => String(offset).padStart(10, '0') + ' 00000 n \n')
          .join('') +
        `trailer\n<< /Size 9 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`,
    ),
  );
  return Buffer.concat(chunks);
}

test('PDF.js reads and searches both pages of a large PDF through bounded local ranges', async () => {
  const { createPdfRange } = await import(pathToFileURL(target).href),
    { getDocument } = await import('pdfjs-dist/legacy/build/pdf.mjs');
  const data = pdfFixture(),
    original = global.fetch,
    calls = [];
  let task;
  global.fetch = async (url, options = {}) => {
    assert.match(url, /^phosphor-media:\/\/file-preview\//);
    if (options.method === 'HEAD')
      return new Response(null, { headers: { 'Content-Length': String(data.length) } });
    const match = /^bytes=(\d+)-(\d+)$/.exec(options.headers.Range);
    assert.ok(match);
    const start = Number(match[1]),
      end = Number(match[2]);
    assert.ok(end - start + 1 <= 1024 * 1024);
    calls.push(end - start + 1);
    return new Response(data.subarray(start, end + 1), {
      status: 206,
      headers: { 'Content-Range': `bytes ${start}-${end}/${data.length}` },
    });
  };
  try {
    const controller = new AbortController(),
      range = await createPdfRange(
        'phosphor-media://file-preview/' + 'p'.repeat(43),
        controller,
        (error) => assert.fail(String(error)),
      );
    task = getDocument({
      range,
      rangeChunkSize: 1024 * 1024,
      disableAutoFetch: true,
      disableStream: true,
      useSystemFonts: true,
    });
    const pdf = await task.promise;
    assert.equal(pdf.numPages, 2);
    for (let number = 1; number <= 2; number++) {
      const content = await (await pdf.getPage(number)).getTextContent();
      assert.match(
        content.items.map((item) => item.str || '').join(' '),
        new RegExp((number === 1 ? 'First' : 'Second') + ' Phosphor fixture page'),
      );
    }
    assert.ok(
      calls.reduce((sum, size) => sum + size, 0) < 3 * 1024 * 1024,
      'Most of the unused stream should not download',
    );
    await task.destroy();
    task = null;
    assert.ok(controller.signal.aborted);
  } finally {
    if (task) await task.destroy();
    global.fetch = original;
  }
});

test('PDF transport rejects arbitrary URLs and mismatched response ranges', async () => {
  const { createPdfRange } = await import(pathToFileURL(target).href),
    original = global.fetch;
  let calls = 0;
  global.fetch = async () => {
    calls++;
    return calls === 1
      ? new Response(null, { headers: { 'Content-Length': '100' } })
      : new Response(new Uint8Array(100), {
          status: 206,
          headers: { 'Content-Range': 'bytes 0-99/101' },
        });
  };
  try {
    for (const url of [
      'https://example.com/a.pdf',
      'file:///C:/private.pdf',
      'phosphor-media://user@file-preview/' + 'p'.repeat(43),
      'phosphor-media://file-preview:44/' + 'p'.repeat(43),
      'phosphor-media://file-preview/' + 'p'.repeat(43) + '#fragment',
      'phosphor-media://file-preview/' + 'p'.repeat(43) + '?path=secret',
    ])
      await assert.rejects(
        createPdfRange(url, new AbortController(), () => {}),
        /Choose a PDF/,
      );
    assert.equal(calls, 0);
    await assert.rejects(
      createPdfRange(
        'phosphor-media://file-preview/' + 'p'.repeat(43),
        new AbortController(),
        () => {},
      ),
      /validated byte range/,
    );
  } finally {
    global.fetch = original;
  }
});
