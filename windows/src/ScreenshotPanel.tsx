import { useEffect, useRef, useState } from 'react';
import { Camera, Info, RefreshCw } from 'lucide-react';
import { api, type Row } from './api';
import { Button, errorMessage } from './ui';

export default function ScreenshotPanel({
  deviceId,
  busy,
  notify,
  revision = 0,
}: {
  deviceId: string;
  busy: boolean;
  notify: (message: string, error?: boolean) => void;
  revision?: number;
}) {
  const [capability, setCapability] = useState<Row | null>(null),
    [checking, setChecking] = useState(false),
    [error, setError] = useState('');
  const identity = useRef(deviceId);
  identity.current = deviceId;
  useEffect(() => {
    setCapability(null);
    setChecking(false);
    setError('');
  }, [deviceId]);
  useEffect(() => {
    setCapability(null);
  }, [revision]);
  async function check() {
    if (busy || checking) return;
    const requested = deviceId;
    setChecking(true);
    setError('');
    try {
      const result = await api.call('screenshotCapabilities', { udid: requested });
      if (identity.current === requested) setCapability(result);
    } catch (value) {
      if (identity.current === requested) setError(errorMessage(value));
    } finally {
      if (identity.current === requested) setChecking(false);
    }
  }
  async function capture() {
    if (busy || checking || !capability?.canAttempt) return;
    const requested = deviceId;
    setChecking(true);
    setError('');
    try {
      const path = await api.choose('save', { name: 'iPhone-screenshot.png' });
      if (!path || identity.current !== requested) return;
      await api.call('screenshot', { udid: requested, path });
      notify('Screenshot capture started. Follow progress in Activity.');
    } catch (value) {
      const message = errorMessage(value);
      if (identity.current === requested) setError(message);
      notify(message, true);
    } finally {
      if (identity.current === requested) setChecking(false);
    }
  }
  async function prepare() {
    if (busy || checking || capability?.developerMode !== true) return;
    const requested = deviceId;
    setChecking(true);
    setError('');
    try {
      await api.call('prepareScreenshot', { udid: requested });
      if (identity.current === requested) setCapability(null);
      notify(
        'Preparing developer support. Follow progress in Activity, then check availability again.',
      );
    } catch (value) {
      const message = errorMessage(value);
      if (identity.current === requested) setError(message);
      notify(message, true);
    } finally {
      if (identity.current === requested) setChecking(false);
    }
  }
  return (
    <section className="panel">
      <div className="section-heading">
        <h3>
          <Camera size={19} /> Screenshot
        </h3>
        <span className="muted">Developer service</span>
      </div>
      <p className="setting-note">
        Remote capture uses Apple’s developer services. Check availability first. Prepare downloads
        and installs compatible signed developer support; it does not change Developer Mode or
        restart the iPhone.
      </p>
      {capability ? (
        <>
          <p className="setting-note" role="status">
            {capability.message}
          </p>
          <dl>
            {(capability.requirements || []).map((item: Row) => (
              <div key={item.id}>
                <dt>{item.label}</dt>
                <dd>
                  {item.state === 'ready'
                    ? 'Ready'
                    : item.state === 'missing'
                      ? 'Setup needed'
                      : 'Not verified'}
                </dd>
              </div>
            ))}
          </dl>
          {capability.status !== 'eligible' ? (
            <details>
              <summary>Setup requirements</summary>
              {(capability.requirements || [])
                .filter((item: Row) => item.state !== 'ready')
                .map((item: Row) => (
                  <p className="setting-note" key={item.id}>
                    {item.instruction}
                  </p>
                ))}
              <p className="setting-note">
                For iOS 17 and later, use a developer tunnel for this iPhone. USB supports a
                temporary tunnel on compatible devices. Phosphor does not enable Developer Mode,
                restart the iPhone, or install a developer image during capture.
              </p>
            </details>
          ) : null}
        </>
      ) : null}
      {error ? (
        <div className="notice error" role="alert">
          <Info size={17} />
          <span>{error}</span>
        </div>
      ) : null}
      <div className="inline-actions">
        <Button icon={RefreshCw} disabled={busy} loading={checking} onClick={() => void check()}>
          {capability ? 'Check again' : 'Check availability'}
        </Button>
        {capability?.developerMode === true && capability.developerImageMounted !== true ? (
          <Button disabled={busy || checking} onClick={() => void prepare()}>
            Prepare screenshots
          </Button>
        ) : null}
        <Button
          icon={Camera}
          variant="primary"
          disabled={busy || checking || !capability?.canAttempt}
          onClick={() => void capture()}
        >
          Save screenshot
        </Button>
      </div>
    </section>
  );
}
