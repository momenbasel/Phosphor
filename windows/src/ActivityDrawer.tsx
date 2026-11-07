import { Activity, CheckCircle2, FolderOpen, Info, Loader2, X } from 'lucide-react';
import { api } from './api';
import { useApp } from './appModel';
import { Button, Empty, date } from './ui';

/** Running and recent jobs with progress, cancellation, and output shortcuts. */
export default function ActivityDrawer({ onClose }: { onClose: () => void }) {
  const { jobs, perform } = useApp();
  return (
    <div className="activity-drawer">
      <header>
        <h2>Activity</h2>
        <button className="icon-button" aria-label="Close activity" onClick={onClose}>
          <X size={20} />
        </button>
      </header>
      {jobs.length ? (
        [...jobs].reverse().map((job) => (
          <article className="job-card" key={job.id}>
            <div className="job-heading">
              {job.status === 'running' ? (
                <Loader2 className="spin" size={18} />
              ) : job.status === 'completed' ? (
                <CheckCircle2 size={18} />
              ) : (
                <Info size={18} />
              )}
              <b>{job.title}</b>
              <span>{job.status}</span>
            </div>
            <p>{job.detail}</p>
            {job.status === 'running' && (
              <>
                <div
                  className="progress-track"
                  role="progressbar"
                  aria-label={job.title}
                  aria-valuemin={0}
                  aria-valuemax={100}
                  aria-valuenow={Math.round(job.percent)}
                >
                  <i style={{ width: job.percent + '%' }} />
                </div>
                <div className="job-footer">
                  <span>{Math.round(job.percent)}%</span>
                  <button onClick={() => perform(() => api.call('cancelJob', { id: job.id }))}>
                    Cancel operation
                  </button>
                </div>
              </>
            )}
            {job.result?.output && (
              <Button
                icon={FolderOpen}
                onClick={() => perform(() => api.reveal(job.result.output))}
              >
                Show in Explorer
              </Button>
            )}
            <small>{date(job.started)}</small>
          </article>
        ))
      ) : (
        <Empty
          icon={Activity}
          title="No recent activity"
          description="Backups, transfers, and exports appear here."
        />
      )}
      <p className="drawer-note">Operations continue when you change pages.</p>
    </div>
  );
}
