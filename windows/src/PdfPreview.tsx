import { useEffect, useRef, useState, type FormEvent } from 'react';
import {
  ChevronLeft,
  ChevronRight,
  Copy,
  FileText,
  Loader2,
  Search,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import {
  getDocument,
  GlobalWorkerOptions,
  PasswordResponses,
  type PDFDocumentProxy,
  type PDFDocumentLoadingTask,
  type RenderTask,
} from 'pdfjs-dist';
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url';
import { createPdfRange } from './pdf_range';
import { Button, errorMessage } from './ui';
import './pdf_preview.css';

GlobalWorkerOptions.workerSrc = workerUrl;
const MAX_PIXELS = 12_000_000,
  SEARCH_PAGES = 500;
export default function PdfPreview({
  url,
  name,
  onError,
  onReady,
}: {
  url: string;
  name: string;
  onError?: (message: string) => void;
  onReady?: (data: {
    page: number;
    width: number;
    height: number;
    text: string;
    ink: boolean;
  }) => void;
}) {
  const [document, setDocument] = useState<PDFDocumentProxy | null>(null),
    [page, setPage] = useState(1),
    [zoom, setZoom] = useState(1);
  const [loading, setLoading] = useState(true),
    [rendering, setRendering] = useState(false),
    [error, setError] = useState(''),
    [text, setText] = useState('');
  const [query, setQuery] = useState(''),
    [matches, setMatches] = useState<number[]>([]),
    [match, setMatch] = useState(0),
    [searching, setSearching] = useState(false),
    [searchStatus, setSearchStatus] = useState('');
  const [password, setPassword] = useState(''),
    [passwordPrompt, setPasswordPrompt] = useState('');
  const canvas = useRef<HTMLCanvasElement>(null),
    loadingTask = useRef<PDFDocumentLoadingTask | null>(null),
    passwordReply = useRef<((password: string) => void) | null>(null);
  const renderSequence = useRef(0),
    searchSequence = useRef(0),
    errorCallback = useRef(onError);
  errorCallback.current = onError;
  const readyCallback = useRef(onReady);
  readyCallback.current = onReady;
  useEffect(() => {
    let active = true;
    setDocument(null);
    setLoading(true);
    setError('');
    setPage(1);
    setText('');
    setMatches([]);
    setSearchStatus('');
    setSearching(false);
    setPassword('');
    setPasswordPrompt('');
    searchSequence.current++;
    const assets = new URL('pdfjs/', window.location.href).href;
    const controller = new AbortController();
    let task: PDFDocumentLoadingTask | undefined;
    const fail = (error: unknown) => {
      if (active) {
        controller.abort();
        setLoading(false);
        const message = errorMessage(error);
        setError(message);
        errorCallback.current?.(message);
        void task?.destroy();
      }
    };
    void createPdfRange(url, controller, fail)
      .then((range) => {
        if (!active) {
          range.abort();
          return;
        }
        task = getDocument({
          range,
          rangeChunkSize: 1024 * 1024,
          disableAutoFetch: true,
          disableStream: true,
          enableXfa: false,
          maxImageSize: MAX_PIXELS,
          canvasMaxAreaInBytes: MAX_PIXELS * 4,
          cMapUrl: assets + 'cmaps/',
          cMapPacked: true,
          standardFontDataUrl: assets + 'standard_fonts/',
          wasmUrl: assets + 'wasm/',
          iccUrl: assets + 'iccs/',
          useWorkerFetch: false,
          useSystemFonts: true,
        });
        loadingTask.current = task;
        task.onPassword = (update: (password: string) => void, reason: number) => {
          if (!active) return;
          passwordReply.current = update;
          setPassword('');
          setPasswordPrompt(
            reason === PasswordResponses.INCORRECT_PASSWORD
              ? 'That PDF password was not accepted. Try again.'
              : 'This PDF requires its document password.',
          );
          setLoading(false);
        };
        return task.promise
          .then((value) => {
            if (active) {
              setDocument(value);
              setPasswordPrompt('');
              setPassword('');
              passwordReply.current = null;
            }
          })
          .finally(() => {
            if (active) setLoading(false);
          });
      })
      .catch(fail);
    return () => {
      active = false;
      controller.abort();
      searchSequence.current++;
      renderSequence.current++;
      passwordReply.current = null;
      loadingTask.current = null;
      void task?.destroy();
    };
  }, [url]);
  useEffect(() => {
    if (!document) return;
    const sequence = ++renderSequence.current;
    let renderingTask: RenderTask | undefined;
    let active = true;
    setRendering(true);
    setError('');
    setText('');
    const draw = async () => {
      const pdfPage = await document.getPage(page);
      if (!active) return;
      const target = canvas.current;
      if (!target) return;
      const viewport = pdfPage.getViewport({ scale: zoom }),
        ratio = Math.min(
          window.devicePixelRatio || 1,
          2,
          Math.sqrt(MAX_PIXELS / (viewport.width * viewport.height)),
        );
      if (!Number.isFinite(ratio) || ratio <= 0)
        throw Error('This PDF page has invalid dimensions.');
      target.width = Math.max(1, Math.floor(viewport.width * ratio));
      target.height = Math.max(1, Math.floor(viewport.height * ratio));
      target.style.width = viewport.width + 'px';
      target.style.height = viewport.height + 'px';
      renderingTask = pdfPage.render({
        canvas: target,
        viewport,
        transform: ratio === 1 ? undefined : [ratio, 0, 0, ratio, 0, 0],
      });
      const [, content] = await Promise.all([renderingTask.promise, pdfPage.getTextContent()]),
        pageText = content.items
          .map((item) => ('str' in item ? item.str : ''))
          .join(' ')
          .slice(0, 1_000_000);
      if (active) setText(pageText);
      if (active && readyCallback.current) {
        const context = target.getContext('2d');
        if (!context) throw Error('The PDF canvas context is unavailable.');
        const pixels = context.getImageData(0, 0, target.width, target.height).data;
        let ink = false;
        for (let index = 0; index < pixels.length; index += 4) {
          if (
            pixels[index + 3] >= 200 &&
            pixels[index] < 200 &&
            pixels[index + 1] < 200 &&
            pixels[index + 2] < 200
          ) {
            ink = true;
            break;
          }
        }
        readyCallback.current({
          page,
          width: target.width,
          height: target.height,
          text: pageText,
          ink,
        });
      }
    };
    draw()
      .catch((e) => {
        if (active && e?.name !== 'RenderingCancelledException') {
          const message = errorMessage(e);
          setError(message);
          errorCallback.current?.(message);
        }
      })
      .finally(() => {
        if (active && sequence === renderSequence.current) setRendering(false);
      });
    return () => {
      active = false;
      renderingTask?.cancel();
    };
  }, [document, page, zoom]);
  const search = async (event: FormEvent) => {
    event.preventDefault();
    if (!document || !query.trim()) return;
    const sequence = ++searchSequence.current;
    const needle = query.trim().toLocaleLowerCase();
    setSearching(true);
    setMatches([]);
    setSearchStatus('');
    const found: number[] = [];
    try {
      for (let number = 1; number <= Math.min(document.numPages, SEARCH_PAGES); number++) {
        const pdfPage = await document.getPage(number);
        const content = await pdfPage.getTextContent();
        if (sequence !== searchSequence.current) return;
        if (
          content.items
            .map((item) => ('str' in item ? item.str : ''))
            .join(' ')
            .toLocaleLowerCase()
            .includes(needle)
        )
          found.push(number);
        if (number % 20 === 0) await new Promise((resolve) => setTimeout(resolve, 0));
      }
      if (sequence === searchSequence.current) {
        setMatches(found);
        setMatch(0);
        if (found.length) setPage(found[0]);
        setSearchStatus(
          found.length
            ? `${found.length} matching pages${document.numPages > SEARCH_PAGES ? ' in the first 500 pages' : ''}.`
            : `No matching text${document.numPages > SEARCH_PAGES ? ' in the first 500 pages' : ''}. Scanned pages need OCR to search.`,
        );
      }
    } catch (e) {
      if (sequence === searchSequence.current) setSearchStatus(errorMessage(e));
    } finally {
      if (sequence === searchSequence.current) setSearching(false);
    }
  };
  const moveMatch = (step: number) => {
    if (!matches.length) return;
    const next = (match + step + matches.length) % matches.length;
    setMatch(next);
    setPage(matches[next]);
  };
  const unlock = (event: FormEvent) => {
    event.preventDefault();
    if (!password || !passwordReply.current) return;
    const secret = password;
    setPassword('');
    setLoading(true);
    passwordReply.current(secret);
  };
  return (
    <section className="pdf-preview" aria-label={'PDF preview: ' + name}>
      <div className="pdf-toolbar">
        <div className="pdf-page-controls">
          <Button
            icon={ChevronLeft}
            disabled={!document || page <= 1 || rendering}
            onClick={() => setPage((value) => value - 1)}
          >
            Previous
          </Button>
          <label>
            Page{' '}
            <input
              type="number"
              min={1}
              max={document?.numPages || 1}
              disabled={!document || rendering}
              value={page}
              onChange={(event) => {
                const value = Number(event.target.value);
                if (Number.isInteger(value) && value >= 1 && value <= (document?.numPages || 1))
                  setPage(value);
              }}
            />{' '}
            <span>of {document?.numPages || '—'}</span>
          </label>
          <Button
            icon={ChevronRight}
            disabled={!document || page >= document.numPages || rendering}
            onClick={() => setPage((value) => value + 1)}
          >
            Next
          </Button>
        </div>
        <div className="pdf-zoom">
          <button
            className="icon-button"
            aria-label="Zoom out"
            disabled={!document || zoom <= 0.5 || rendering}
            onClick={() => setZoom((value) => Math.max(0.5, value - 0.25))}
          >
            <ZoomOut size={17} />
          </button>
          <span>{Math.round(zoom * 100)}%</span>
          <button
            className="icon-button"
            aria-label="Zoom in"
            disabled={!document || zoom >= 3 || rendering}
            onClick={() => setZoom((value) => Math.min(3, value + 0.25))}
          >
            <ZoomIn size={17} />
          </button>
        </div>
      </div>
      <form className="pdf-search" onSubmit={(event) => void search(event)}>
        <Search size={16} />
        <input
          type="search"
          aria-label="Find text in this PDF"
          placeholder="Find text in this PDF"
          maxLength={512}
          value={query}
          disabled={!document}
          onChange={(event) => {
            searchSequence.current++;
            setSearching(false);
            setMatches([]);
            setSearchStatus('');
            setQuery(event.target.value);
          }}
        />
        <Button
          type="submit"
          disabled={!document || !query.trim() || searching}
          loading={searching}
        >
          Find
        </Button>
        {matches.length > 0 && (
          <>
            <button
              className="icon-button"
              aria-label="Previous matching page"
              onClick={() => moveMatch(-1)}
            >
              <ChevronLeft size={16} />
            </button>
            <span>
              {match + 1}/{matches.length}
            </span>
            <button
              className="icon-button"
              aria-label="Next matching page"
              onClick={() => moveMatch(1)}
            >
              <ChevronRight size={16} />
            </button>
          </>
        )}
      </form>
      {searchStatus && (
        <p className="pdf-search-status" role="status">
          {searchStatus}
        </p>
      )}
      {passwordPrompt && (
        <form className="pdf-password" onSubmit={unlock}>
          <p>{passwordPrompt}</p>
          <input
            type="password"
            aria-label="PDF document password"
            autoComplete="off"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
          />
          <Button type="submit" disabled={!password || loading}>
            Open PDF
          </Button>
        </form>
      )}
      {error && (
        <p className="pdf-error" role="alert">
          {error}
        </p>
      )}
      <div className="pdf-page-surface" aria-busy={loading || rendering}>
        {(loading || rendering) && (
          <div className="pdf-loading" role="status">
            <Loader2 className="spin" size={22} />
            <span>{document ? 'Rendering page…' : 'Opening PDF…'}</span>
          </div>
        )}
        <canvas
          ref={canvas}
          aria-label={'PDF page ' + page}
          style={{ visibility: document && !error && !rendering ? 'visible' : 'hidden' }}
        />
      </div>
      {document && (
        <details className="pdf-page-text">
          <summary>
            <FileText size={15} /> Text on this page
          </summary>
          <Button
            icon={Copy}
            disabled={!text}
            onClick={() =>
              void navigator.clipboard
                .writeText(text)
                .catch(() =>
                  setSearchStatus(
                    'The clipboard could not be accessed. Select the page text to copy it.',
                  ),
                )
            }
          >
            Copy page text
          </Button>
          <p>{text || 'No extractable text on this page.'}</p>
        </details>
      )}
    </section>
  );
}
