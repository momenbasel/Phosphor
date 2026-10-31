import { useState } from 'react';
import { ArrowRight, Search } from 'lucide-react';
import { navigation, type Page } from './navigation';
import { Modal } from './ui';

/** Ctrl+K page finder. */
export default function CommandPalette({
  onNavigate,
  onClose,
}: {
  onNavigate: (page: Page) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState('');
  const matches = navigation.filter((item) =>
    item.label.toLowerCase().includes(query.toLowerCase()),
  );
  return (
    <Modal title="Find a page" onClose={onClose}>
      <div className="palette-search">
        <Search size={20} />
        <input
          aria-label="Search pages"
          placeholder="Search pages…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </div>
      <div className="palette-results">
        {matches.map((item) => (
          <button key={item.page} onClick={() => onNavigate(item.page)}>
            <item.icon size={19} />
            <span>{item.label}</span>
            <ArrowRight size={15} />
          </button>
        ))}
      </div>
      <p className="palette-hint">Tab to navigate · Enter to select · Esc to close</p>
    </Modal>
  );
}
