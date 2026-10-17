import { useEffect, useId, useRef, type ReactNode } from 'react';
import { ArrowLeft, ArrowRight, Folder, Loader2, X, type LucideIcon } from 'lucide-react';

export function errorMessage(error: unknown) {
  return (error instanceof Error ? error.message : String(error)).replace(
    /^Error invoking remote method '[^']+':\s*(?:Error:\s*)?/,
    '',
  );
}
export function date(value?: string) {
  if (!value) return '—';
  const d = new Date(value);
  return Number.isNaN(d.getTime())
    ? value
    : d.toLocaleString(undefined, {
        month: 'short',
        day: 'numeric',
        year: 'numeric',
        hour: 'numeric',
        minute: '2-digit',
      });
}
export function bytes(value?: number) {
  if (value == null) return '—';
  if (value <= 0) return '0 B';
  const i = Math.min(4, Math.floor(Math.log(value) / Math.log(1024)));
  return (value / 1024 ** i).toFixed(i ? 1 : 0) + ' ' + ['B', 'KB', 'MB', 'GB', 'TB'][i];
}
export function Button({
  children,
  onClick,
  variant = 'secondary',
  disabled = false,
  loading = false,
  icon: Icon,
  type = 'button',
}: {
  children: ReactNode;
  onClick?: () => void;
  variant?: string;
  disabled?: boolean;
  loading?: boolean;
  icon?: LucideIcon;
  type?: 'button' | 'submit';
}) {
  return (
    <button
      type={type}
      className={'button ' + variant}
      onClick={onClick}
      disabled={disabled || loading}
      aria-busy={loading}
    >
      {loading ? (
        <Loader2 className="spin" size={16} />
      ) : (
        Icon && <Icon className={Icon === Loader2 ? 'spin' : undefined} size={16} />
      )}{' '}
      {children}
    </button>
  );
}
export function Badge({ children, good = false }: { children: ReactNode; good?: boolean }) {
  return (
    <span className={'badge ' + (good ? 'good' : '')}>
      <span className="status-dot" />
      {children}
    </span>
  );
}

export function Empty({
  icon: Icon = Folder,
  title,
  description,
  action,
}: {
  icon?: LucideIcon;
  title: string;
  description: string;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      <div className="empty-icon">
        <Icon size={28} strokeWidth={1.5} />
      </div>
      <h3>{title}</h3>
      <p>{description}</p>
      {action}
    </div>
  );
}
export function Loading({ label = 'Loading…' }: { label?: string }) {
  return (
    <div className="panel loading-panel" role="status">
      <Loader2 className="spin" size={24} />
      <span>{label}</span>
    </div>
  );
}
export function Pager({
  offset,
  total,
  limit,
  onChange,
}: {
  offset: number;
  total: number;
  limit: number;
  onChange: (offset: number) => void;
}) {
  return (
    <div className="pager">
      <Button
        icon={ArrowLeft}
        disabled={!offset}
        onClick={() => onChange(Math.max(0, offset - limit))}
      >
        Previous
      </Button>
      <span>
        {total
          ? `${offset + 1}–${Math.min(offset + limit, total)} of ${total.toLocaleString()}`
          : '0 items'}
      </span>
      <Button
        icon={ArrowRight}
        disabled={offset + limit >= total}
        onClick={() => onChange(offset + limit)}
      >
        Next
      </Button>
    </div>
  );
}
export function Modal({
  title,
  children,
  onClose,
}: {
  title: string;
  children: ReactNode;
  onClose: () => void;
}) {
  const id = useId(),
    ref = useRef<HTMLDivElement>(null),
    closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    const previous = document.activeElement as HTMLElement;
    const el = ref.current;
    (
      el?.querySelector<HTMLElement>('input,select,textarea') ||
      el?.querySelector<HTMLElement>('button')
    )?.focus();
    const listener = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        closeRef.current();
      }
      if (e.key === 'Tab' && el) {
        const items = [
          ...el.querySelectorAll<HTMLElement>(
            'button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex="0"]',
          ),
        ].filter((item) => item.getClientRects().length);
        const first = items[0],
          last = items.at(-1);
        if (e.shiftKey && document.activeElement === first) {
          last?.focus();
          e.preventDefault();
        } else if (!e.shiftKey && document.activeElement === last) {
          first?.focus();
          e.preventDefault();
        }
      }
    };
    document.addEventListener('keydown', listener);
    return () => {
      document.removeEventListener('keydown', listener);
      previous?.focus();
    };
  }, []);
  return (
    <div
      className="modal-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div ref={ref} className="modal" role="dialog" aria-modal="true" aria-labelledby={id}>
        <header>
          <h2 id={id}>{title}</h2>
          <button className="icon-button" aria-label="Close dialog" onClick={onClose}>
            <X size={19} />
          </button>
        </header>
        {children}
      </div>
    </div>
  );
}
