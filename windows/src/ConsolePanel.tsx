import { useEffect, useState } from 'react';
import { Copy, Download, FolderOpen, Terminal, Trash2, X } from 'lucide-react';
import { api, type Row } from './api';
import { Button, Modal, bytes, date, errorMessage } from './ui';
export default function ConsolePanel({
  deviceId,
  jobs,
  notify,
}: {
  deviceId: string;
  jobs: Row[];
  notify: (message: string, error?: boolean) => void;
}) {
  const [lines, setLines] = useState<string[]>([]),
    [saved, setSaved] = useState<Row[]>([]),
    [busy, setBusy] = useState(false),
    [preview, setPreview] = useState<Row | null>(null);
  const active = jobs.some((job) => job.title === 'Device console' && job.status === 'running');
  useEffect(() => {
    let alive = true;
    api
      .call('logs')
      .then((result) => {
        if (alive) setLines(result);
      })
      .catch(() => {});
    api
      .call('consoleSaved')
      .then((result) => {
        if (alive) setSaved(result);
      })
      .catch(() => {});
    const off = api.onEvent((event) => {
      if (event.event === 'log') setLines((old) => [...old.slice(-1999), event.data]);
    });
    return () => {
      alive = false;
      off();
    };
  }, [deviceId]);
  const perform = async (action: () => Promise<void>) => {
    setBusy(true);
    try {
      await action();
    } catch (error) {
      notify(errorMessage(error), true);
    } finally {
      setBusy(false);
    }
  };
  const open = (id: string) =>
    perform(async () => setPreview(await api.call('consoleOpen', { id })));
  return (
    <section className="panel console-panel">
      <div className="section-heading">
        <h3>
          <Terminal size={19} /> Device console
        </h3>
        <div className="inline-actions">
          <Button
            icon={Terminal}
            disabled={busy || active}
            onClick={() =>
              perform(async () => {
                await api.call('startLogs', { udid: deviceId });
              })
            }
          >
            Start stream
          </Button>
          <Button
            icon={X}
            disabled={busy || !active}
            onClick={() =>
              perform(async () => {
                await api.call('stopLogs');
              })
            }
          >
            Stop
          </Button>
        </div>
      </div>
      <div className="console-actions">
        <span className="muted">{lines.length.toLocaleString()} recent lines</span>
        <Button
          icon={Trash2}
          disabled={!lines.length || busy}
          onClick={() =>
            perform(async () => {
              await api.call('consoleClear');
              setLines([]);
            })
          }
        >
          Clear
        </Button>
        <Button
          icon={Copy}
          disabled={!lines.length || busy}
          onClick={() =>
            perform(async () => {
              await navigator.clipboard.writeText(lines.join('\n'));
              notify('Console text copied');
            })
          }
        >
          Copy
        </Button>
        <Button
          icon={Download}
          disabled={!lines.length || busy}
          loading={busy}
          onClick={() =>
            perform(async () => {
              const row = await api.call('consoleSave');
              setSaved((old) => [row, ...old]);
              notify('Transcript saved locally');
            })
          }
        >
          Save as TXT
        </Button>
        <Button
          icon={FolderOpen}
          disabled={!saved.length || busy || saved[0]?.missing}
          onClick={() => open(saved[0].id)}
        >
          Open latest saved
        </Button>
      </div>
      <pre aria-label="Device console output">
        {lines.length
          ? lines.slice(-1000).join('\n')
          : 'Start the stream to view device system messages.'}
      </pre>
      <details className="console-history">
        <summary>
          Saved transcripts <span>{saved.length}</span>
        </summary>
        {saved.length ? (
          <div className="console-saved-list">
            {saved.map((row) => (
              <div key={row.id}>
                <div>
                  <b>{row.name}</b>
                  <small>
                    {date(row.date)} · {bytes(row.bytes)}
                    {row.missing ? ' · File moved or removed' : ''}
                  </small>
                </div>
                <Button disabled={row.missing || busy} onClick={() => open(row.id)}>
                  Open
                </Button>
                <Button
                  icon={FolderOpen}
                  disabled={row.missing || busy}
                  onClick={() =>
                    perform(async () => {
                      await api.reveal(row.path);
                    })
                  }
                >
                  Show folder
                </Button>
              </div>
            ))}
          </div>
        ) : (
          <p className="setting-note">
            Saved device streams appear here. Clearing the live console keeps saved files.
          </p>
        )}
      </details>
      {preview && (
        <Modal title={preview.name} onClose={() => setPreview(null)}>
          <div className="inline-actions">
            <Button
              icon={Copy}
              onClick={() =>
                perform(async () => {
                  await navigator.clipboard.writeText(preview.text);
                  notify('Saved transcript text copied');
                })
              }
            >
              Copy
            </Button>
            <Button
              icon={FolderOpen}
              onClick={() =>
                perform(async () => {
                  await api.reveal(preview.path);
                })
              }
            >
              Show in Explorer
            </Button>
          </div>
          <pre className="saved-console-preview">
            {preview.text}
            {preview.truncated
              ? '\n\nPreview limited to 1 MB. Open the saved TXT for all lines.'
              : ''}
          </pre>
        </Modal>
      )}
    </section>
  );
}
