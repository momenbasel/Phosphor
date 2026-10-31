import { useState } from 'react';
import { Wifi, Trash2, Loader2 } from 'lucide-react';
import { type Row } from './api';

export default function WifiConnection({
  saved,
  busy,
  onConnect,
  onForget,
}: {
  saved: Row[];
  busy: boolean;
  onConnect: (address: string) => void;
  onForget: (id: string) => void;
}) {
  const [address, setAddress] = useState(saved[0]?.address || '');
  return (
    <section className="wifi-connection" aria-label="Wi-Fi connection">
      <div className="setting-heading">
        <Wifi size={22} />
        <div>
          <h3>Connect over Wi-Fi.</h3>
          <p>Trust this PC by USB once. Then keep both devices on the same network.</p>
        </div>
      </div>
      <label className="form-label">
        iPhone IP address
        <input
          value={address}
          onChange={(e) => setAddress(e.target.value)}
          placeholder="e.g. 10.0.0.131"
          autoComplete="off"
          spellCheck={false}
          disabled={busy}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              if (!busy && address.trim()) onConnect(address);
            }
          }}
        />
      </label>
      <p className="setting-note">
        Find it on your iPhone: Settings → Wi-Fi → ⓘ beside your network → IP Address. Phosphor
        remembers trusted devices and reconnects automatically.
      </p>
      <button
        type="button"
        className="button primary"
        disabled={busy || !address.trim()}
        onClick={() => onConnect(address)}
      >
        {busy ? <Loader2 size={16} className="spin" /> : <Wifi size={16} />}{' '}
        {busy ? 'Connecting…' : 'Connect over Wi-Fi'}
      </button>
      {saved.map((row) => (
        <div className="schedule-row" key={row.id}>
          <Wifi size={19} />
          <div>
            <b>{row.name}</b>
            <small>{row.address}</small>
          </div>
          <button
            type="button"
            className="icon-button"
            disabled={busy}
            aria-label={'Forget Wi-Fi connection for ' + row.name}
            onClick={() => onForget(row.id)}
          >
            <Trash2 size={17} />
          </button>
        </div>
      ))}
    </section>
  );
}
