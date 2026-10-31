import { useEffect, useState } from 'react';
import { Info, Package, Search, Trash2 } from 'lucide-react';
import { api, type Row } from '../api';
import { useApp } from '../appModel';
import IpaInstall from '../IpaInstall';
import { Button, Empty, Loading, errorMessage } from '../ui';

export default function AppsView() {
  const { deviceId, revision, notify, confirm, reload } = useApp();
  const [apps, setApps] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');

  useEffect(() => {
    const timer = setTimeout(() => setQuery(search.toLowerCase()), 250);
    return () => clearTimeout(timer);
  }, [search]);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    setError('');
    api
      .call('apps', { udid: deviceId })
      .then((rows) => {
        if (alive) setApps(rows);
      })
      .catch((reason) => {
        if (alive) setError(errorMessage(reason));
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [deviceId, revision]);

  const visible = apps.filter((app) => (app.name + ' ' + app.detail).toLowerCase().includes(query));
  return (
    <>
      <div className="toolbar">
        <label className="search-field">
          <Search size={16} />
          <input
            type="search"
            aria-label="Find an application"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Find an application"
          />
        </label>
        <span className="toolbar-count">{apps.length} installed apps</span>
        <IpaInstall deviceId={deviceId} notify={notify} />
      </div>
      <div className="notice">
        <Info size={17} /> iOS requires a correctly signed IPA and valid provisioning. Phosphor does
        not bypass Apple’s signing rules.
      </div>
      {loading ? (
        <Loading label="Loading applications…" />
      ) : error ? (
        <Empty
          icon={Info}
          title="Apps couldn’t be opened"
          description={error}
          action={<Button onClick={reload}>Try again</Button>}
        />
      ) : (
        <div className="app-grid">
          {visible.map((app) => (
            <article className="app-card panel" key={app.id}>
              <div className="app-glyph">
                <Package size={23} />
              </div>
              <div>
                <b>{app.name}</b>
                <small>{app.detail}</small>
                <span>Version {app.version || '—'}</span>
              </div>
              <button
                className="icon-button danger-text"
                aria-label={'Remove ' + app.name}
                onClick={() =>
                  confirm(
                    'Remove ' + app.name + '?',
                    'Removing this app also removes its local data from the device.',
                    () =>
                      api.call('removeApp', { udid: deviceId, bundle: app.id, confirmed: true }),
                  )
                }
              >
                <Trash2 size={17} />
              </button>
            </article>
          ))}
        </div>
      )}
    </>
  );
}
