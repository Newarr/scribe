// Popover frame — refined header (no status pill clutter), tabs.
const Popover = ({ children, screen, onScreen }) => (
  <div className="popover">
    <div className="pop-head">
      <div className="pop-logo">
        <svg viewBox="0 0 18 18" width="14" height="14" fill="none" aria-hidden>
          <rect x="3"    y="6" width="2" height="6"  rx="0.8" fill="currentColor"/>
          <rect x="6.5"  y="3" width="2" height="12" rx="0.8" fill="currentColor"/>
          <rect x="10"   y="5" width="2" height="8"  rx="0.8" fill="currentColor"/>
          <rect x="13.5" y="7" width="2" height="4"  rx="0.8" fill="currentColor"/>
        </svg>
        <span>scribe</span>
      </div>
      {screen === 'rec' ? (
        <span className="indicator indicator-live"><span className="dot"/>LIVE</span>
      ) : null}
    </div>
    <div className="pop-tabs">
      {[
        { id: 'idle', label: 'Idle' },
        { id: 'rec',  label: 'Recording' },
        { id: 'tx',   label: 'Transcript' },
        { id: 'set',  label: 'Settings' },
      ].map(t => (
        <button key={t.id}
          className={`pop-tab ${screen === t.id ? 'on' : ''}`}
          onClick={() => onScreen(t.id)}>{t.label}</button>
      ))}
    </div>
    <div className="pop-body">{children}</div>
  </div>
);

window.ScribePopover = Popover;
