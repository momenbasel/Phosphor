import { useEffect, useRef, useState } from 'react';
import { ChartNoAxesCombined, Loader2, RefreshCw } from 'lucide-react';
import { api, type Row } from './api';
import { Button, bytes, errorMessage } from './ui';
export default function BackupStorage({
  backup,
  unlocked,
  notify,
  compact = false,
  kind,
}: {
  backup: string;
  unlocked: boolean;
  notify: (message: string, error?: boolean) => void;
  compact?: boolean;
  kind?: string;
}) {
  const [result, setResult] = useState<Row>({}),
    [job, setJob] = useState(''),
    [loading, setLoading] = useState(false),
    [revision, setRevision] = useState(0),
    [show, setShow] = useState(false);
  const scope = useRef(0);
  useEffect(() => {
    scope.current++;
    setResult({});
    setJob('');
    setLoading(false);
  }, [backup, unlocked]);
  useEffect(() => {
    let alive = true;
    api
      .call('backupStats', { backup })
      .then((value) => {
        if (alive) setResult(value);
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [backup, unlocked, revision]);
  useEffect(
    () =>
      api.onEvent((event) => {
        if (
          event.event === 'job' &&
          event.data.id === job &&
          (!event.data.result?.backup || event.data.result.backup === backup)
        ) {
          if (event.data.status === 'completed') {
            setResult(event.data.result || {});
            setJob('');
            setRevision((value) => value + 1);
          } else if (['failed', 'cancelled'].includes(event.data.status)) {
            setJob('');
            if (event.data.status === 'failed') notify(event.data.detail, true);
          }
        }
      }),
    [job, notify, backup],
  );
  const analyze = async () => {
    const requestScope = scope.current;
    setLoading(true);
    try {
      const started = await api.call('backupMeasure', { backup, logical: unlocked });
      if (requestScope !== scope.current) return;
      setJob(started.job);
      const current = await api.call('jobs');
      if (requestScope !== scope.current) return;
      const done = current.find(
        (entry: Row) => entry.id === started.job && entry.status !== 'running',
      );
      if (done) {
        setJob('');
        if (done.status === 'completed') {
          setResult(done.result || {});
          setRevision((value) => value + 1);
        } else notify(done.detail, true);
      }
    } catch (error) {
      notify(errorMessage(error), true);
    } finally {
      if (requestScope === scope.current) setLoading(false);
    }
  };
  const categories: Row[] = result.breakdown?.categories || [],
    category =
      kind === 'backupfiles'
        ? categories
        : kind === 'photos'
          ? categories.filter((row) => ['photos', 'videos'].includes(row.id))
          : categories.filter((row) => row.id === (kind === 'music' ? 'audio' : kind)),
    sectionBytes = category.reduce((total, row) => total + row.bytes, 0),
    sectionCount = category.reduce((total, row) => total + row.count, 0),
    unknown = category.reduce((total, row) => total + row.unknownCount, 0),
    total = result.breakdown?.bytes || 0;
  if (compact)
    return (
      <div className="backup-section-size">
        <ChartNoAxesCombined size={15} />
        <span>
          {category.length
            ? `${unknown ? (sectionBytes ? 'At least ' + bytes(sectionBytes) : 'Size not recorded') : bytes(sectionBytes)} · ${sectionCount.toLocaleString()} backed-up files`
            : result.breakdown
              ? 'No files recorded in this category'
              : 'Section sizes haven’t been analyzed'}
        </span>
        <button className="text-button" disabled={!!job || loading} onClick={analyze}>
          {job || loading ? (
            <>
              <Loader2 className="spin" size={13} />
              Analyzing…
            </>
          ) : (
            'Analyze storage'
          )}
        </button>
      </div>
    );
  return (
    <section className="panel backup-storage">
      <div className="section-heading">
        <div>
          <h3>Backup storage</h3>
          <p className="setting-note">
            {result.physical?.bytes != null
              ? `${bytes(result.physical.bytes)} on disk · ${(result.physical.files || 0).toLocaleString()} files`
              : 'Measure the selected snapshot’s disk size and contents.'}
          </p>
        </div>
        <Button icon={RefreshCw} loading={loading || !!job} onClick={analyze}>
          {job ? 'Analyzing…' : 'Analyze storage'}
        </Button>
      </div>
      {!unlocked && (
        <p className="setting-note">
          The disk size can be measured while encrypted. Unlock this backup for section and domain
          details.
        </p>
      )}
      {categories.length > 0 && (
        <>
          <div className="storage-map" role="group" aria-label="Backup storage map by section">
            {categories
              .filter((row) => row.bytes > 0)
              .map((row, index) => (
                <button
                  key={row.id}
                  style={{
                    flexGrow: row.bytes / total,
                    background: `hsl(${210 + index * 29} 48% 32%)`,
                  }}
                  title={`${row.name}: ${bytes(row.bytes)} · ${row.count.toLocaleString()} files`}
                  onClick={() => setShow(true)}
                >
                  <span>{row.bytes / total > 0.08 ? row.name : ''}</span>
                </button>
              ))}
          </div>
          <div className="storage-category-list">
            {categories.map((row) => (
              <div key={row.id}>
                <span>{row.name}</span>
                <b>
                  {row.unknownCount
                    ? row.bytes
                      ? '≥ ' + bytes(row.bytes)
                      : 'Not recorded'
                    : bytes(row.bytes)}
                </b>
                <small>
                  {row.count.toLocaleString()} files
                  {row.unknownCount ? ` · ${row.unknownCount} sizes unknown` : ''}
                </small>
              </div>
            ))}
          </div>
          <p className="setting-note">
            Section sizes come from the manifest and may differ from encrypted disk usage.{' '}
            {result.breakdown.unknownCount
              ? `${result.breakdown.unknownCount.toLocaleString()} files have no recorded size.`
              : ''}
          </p>
          <details open={show} onToggle={(event) => setShow(event.currentTarget.open)}>
            <summary>Storage by backup domain</summary>
            <div className="storage-domain-list">
              {result.breakdown.domains.map((row: Row) => (
                <div key={row.name}>
                  <span>{row.name}</span>
                  <b>
                    {row.unknownCount
                      ? row.bytes
                        ? '≥ ' + bytes(row.bytes)
                        : 'Not recorded'
                      : bytes(row.bytes)}
                  </b>
                  <small>{row.count.toLocaleString()} files</small>
                </div>
              ))}
            </div>
          </details>
        </>
      )}
      {result.breakdown?.whatsapp && (
        <details className="whatsapp-evidence">
          <summary>WhatsApp backup evidence</summary>
          <p>{result.breakdown.whatsapp.message}</p>
          <p>
            {result.breakdown.whatsapp.fileCount.toLocaleString()} related files ·{' '}
            {result.breakdown.whatsapp.domains.length} domains
          </p>
          {result.breakdown.whatsapp.domains.map((domain: string) => (
            <code key={domain}>{domain}</code>
          ))}
          {result.breakdown.whatsapp.chatDatabases.map((row: Row) => (
            <p key={row.domain + row.path}>
              {row.path}
              {row.emptyPlaceholder
                ? ' · 0 bytes · Empty placeholder'
                : row.encryptedAppData
                  ? ' · WhatsApp-protected archive'
                  : ''}
            </p>
          ))}
        </details>
      )}
    </section>
  );
}
