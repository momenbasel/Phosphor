import { PDFDataRangeTransport } from 'pdfjs-dist';

const CHUNK = 1024 * 1024,
  MAX_RANGE = 64 * CHUNK;
class LocalPdfRange extends PDFDataRangeTransport {
  constructor(
    length: number,
    data: Uint8Array,
    private url: string,
    private controller: AbortController,
    private failed: (error: unknown) => void,
  ) {
    super(length, data, true);
  }
  requestDataRange(begin: number, end: number): void {
    void this.read(begin, end).catch((error) => {
      if (!this.controller.signal.aborted) this.failed(error);
    });
  }
  private async read(begin: number, end: number): Promise<void> {
    if (
      !Number.isSafeInteger(begin) ||
      !Number.isSafeInteger(end) ||
      begin < 0 ||
      end <= begin ||
      end > this.length ||
      end - begin > MAX_RANGE
    )
      throw Error('The PDF requested an invalid or oversized byte range.');
    const result = new Uint8Array(end - begin);
    for (let offset = begin; offset < end; offset += CHUNK) {
      const last = Math.min(end, offset + CHUNK) - 1,
        response = await fetch(this.url, {
          headers: { Range: `bytes=${offset}-${last}` },
          signal: this.controller.signal,
        });
      if (
        response.status !== 206 ||
        response.headers.get('Content-Range') !== `bytes ${offset}-${last}/${this.length}`
      )
        throw Error('The PDF preview expired or could not stream this page.');
      const data = new Uint8Array(await response.arrayBuffer());
      if (data.length !== last - offset + 1)
        throw Error('The PDF preview returned an incomplete byte range.');
      result.set(data, offset - begin);
    }
    if (!this.controller.signal.aborted) this.onDataRange(begin, result);
  }
  abort(): void {
    this.controller.abort();
  }
}
export async function createPdfRange(
  url: string,
  controller: AbortController,
  failed: (error: unknown) => void,
): Promise<PDFDataRangeTransport> {
  const target = new URL(url);
  if (
    target.protocol !== 'phosphor-media:' ||
    target.hostname !== 'file-preview' ||
    target.search ||
    target.hash ||
    target.username ||
    target.password ||
    target.port ||
    !/^\/[-_A-Za-z0-9]{43}$/.test(target.pathname)
  )
    throw Error('Choose a PDF from Phosphor’s file browser.');
  const head = await fetch(url, { method: 'HEAD', signal: controller.signal });
  const length = Number(head.headers.get('Content-Length'));
  if (!head.ok || !Number.isSafeInteger(length) || length <= 0 || length > 512 * CHUNK)
    throw Error('This PDF preview expired or exceeded the bounded cache size.');
  const end = Math.min(length, 65536) - 1,
    response = await fetch(url, {
      headers: { Range: `bytes=0-${end}` },
      signal: controller.signal,
    });
  if (
    response.status !== 206 ||
    response.headers.get('Content-Range') !== `bytes 0-${end}/${length}`
  )
    throw Error('The PDF preview could not open a validated byte range.');
  const initial = new Uint8Array(await response.arrayBuffer());
  if (initial.length !== end + 1) throw Error('The PDF preview is incomplete.');
  return new LocalPdfRange(length, initial, url, controller, failed);
}
