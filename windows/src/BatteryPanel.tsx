import { Battery, Zap } from 'lucide-react';
import type { Row } from './api';

export default function BatteryPanel({ reading }: { reading: Row }) {
  const charge = typeof reading.charge === 'number' ? `${reading.charge}%` : 'Not reported';
  const charging =
    reading.charging === true
      ? 'Charging'
      : reading.charging === false
        ? 'Not charging'
        : 'Not reported';
  return (
    <section className="panel battery-panel">
      <div className="section-heading">
        <h3>
          <Battery size={19} /> Battery
        </h3>
        <span className="badge">Device reported</span>
      </div>
      {reading.error ? (
        <p className="notice error">{reading.error}</p>
      ) : (
        <>
          <div className="battery-charge">
            <strong>{charge}</strong>
            <span>
              {reading.charging === true && <Zap size={16} />} {charging}
            </span>
          </div>
          {typeof reading.charge === 'number' && (
            <div
              className="battery-track"
              role="meter"
              aria-label="Battery charge"
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={reading.charge}
            >
              <i style={{ width: `${reading.charge}%` }} />
            </div>
          )}
          <dl>
            <div>
              <dt>Cycle count</dt>
              <dd>
                {typeof reading.cycles === 'number'
                  ? reading.cycles.toLocaleString()
                  : 'Not reported'}
              </dd>
            </div>
            <div>
              <dt>Maximum capacity</dt>
              <dd>
                {typeof reading.maximumCapacityPercent === 'number'
                  ? `${reading.maximumCapacityPercent}%`
                  : 'Not reported by iOS'}
              </dd>
            </div>
          </dl>
          {reading.maximumCapacityPercent == null && (
            <p className="setting-note">
              For battery health, check Settings → Battery → Battery Health on your iPhone.
            </p>
          )}
          {Object.keys(reading.raw || {}).length > 0 && (
            <details className="battery-raw">
              <summary>All reported readings</summary>
              <pre>{JSON.stringify(reading.raw, null, 2)}</pre>
            </details>
          )}
        </>
      )}
    </section>
  );
}
