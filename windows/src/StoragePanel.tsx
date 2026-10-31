import { HardDrive } from 'lucide-react';
import type { Row } from './api';
function capacity(value: number) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'],
    index = value > 0 ? Math.min(4, Math.floor(Math.log(value) / Math.log(1000))) : 0;
  return `${(value / 1000 ** index).toLocaleString(undefined, { maximumFractionDigits: index ? 1 : 0 })} ${units[index]}`;
}
export default function StoragePanel({ reading }: { reading: Row }) {
  const measurements: Array<{ key: string; label: string; bytes: number; source: string }> =
    Array.isArray(reading.measurements) ? reading.measurements : [];
  const hardware = measurements.find((item) => item.key === 'TotalDiskCapacity');
  const reported = measurements.filter(
    (item) => typeof item.bytes === 'number' && Number.isFinite(item.bytes) && item.bytes >= 0,
  );
  const current = reported.filter((item) =>
    ['FSFreeBytes', 'AmountDataReserved'].includes(item.key),
  );
  return (
    <section className="panel">
      <div className="section-heading">
        <h3>
          <HardDrive size={19} /> Device storage
        </h3>
        <span className="muted">Volume measurements</span>
      </div>
      {reading.availableBytes != null ? (
        <>
          <h2 className="overview-value">{capacity(reading.availableBytes)}</h2>
          <p className="setting-note">
            {reading.availableLabel || 'Reported available data'}
            {hardware ? ` · ${capacity(hardware.bytes)} hardware capacity` : ''}
          </p>
        </>
      ) : hardware ? (
        <>
          <h2 className="overview-value">{capacity(hardware.bytes)}</h2>
          <p className="setting-note">Hardware capacity</p>
        </>
      ) : null}
      <p className="setting-note">
        {reading.message ||
          'A current whole-device available total is not exposed by this connection. Check Settings → General → iPhone Storage for the iPhone’s own calculation.'}
      </p>
      {current.length ? (
        <dl>
          {current.map((item) => (
            <div key={item.key} title={item.source}>
              <dt>{item.label}</dt>
              <dd>{capacity(item.bytes)}</dd>
            </div>
          ))}
        </dl>
      ) : !reported.length ? (
        <p className="setting-note">
          {reading.error || 'No numeric volume measurements were returned.'}
        </p>
      ) : null}
      {reported.length ? (
        <details className="storage-protocol">
          <summary>Original measurements and sources</summary>
          <p className="setting-note">
            {reading.source || 'Apple device storage protocols'}. GB uses decimal units. The legacy
            data-volume free value is retained for diagnosis and is not used as available space.
          </p>
          <dl>
            {reported.map((item) => (
              <div key={item.key} title={item.source}>
                <dt>{item.label}</dt>
                <dd>{capacity(item.bytes)}</dd>
              </div>
            ))}
          </dl>
          {reported.map((item) => (
            <p className="setting-note" key={item.key}>
              {item.label}: {item.source}
            </p>
          ))}
          {reading.checkedAt ? (
            <p className="setting-note">Checked {new Date(reading.checkedAt).toLocaleString()}</p>
          ) : null}
          {reading.raw?.lockdown?.CalculateDiskUsage != null ? (
            <p className="setting-note">
              CalculateDiskUsage is an internal service value, not a storage size or category.
            </p>
          ) : null}
        </details>
      ) : null}
    </section>
  );
}
