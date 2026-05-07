// Saved transcript — title, one meta line, body, system actions.
// No "destinations" or "routing" — Scribe is local. The transcript is the artifact.
const TranscriptScreen = () => (
  <div className="screen">
    <div className="tx-head">
      <div className="tx-title">Acme Q3 sync</div>
      <div className="tx-meta">Today 14:02 · 42 min · 3 speakers</div>
    </div>

    <div className="tx-body">
      <div className="tx-line"><span className="speaker s-1">Maya</span><span className="text">Ship v2 by end of Q3, gate pricing behind a flag, roll out in two cohorts.</span></div>
      <div className="tx-line"><span className="speaker s-2">Devon</span><span className="text">Cohort one annual, two monthly. What about the legacy webhook?</span></div>
      <div className="tx-line"><span className="speaker s-1">Maya</span><span className="text">Keep it 90 days post-cutover. I'll write the migration doc by Friday.</span></div>
      <div className="tx-line"><span className="speaker s-3">Priya</span><span className="text">I'll loop in support and update the help center.</span></div>
    </div>

    <div className="tx-foot">
      <div className="tx-actions-primary">
        <button className="btn btn-secondary btn-sm">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" width="13" height="13"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
          Copy
        </button>
        <button className="btn btn-ghost btn-sm">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" width="13" height="13"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
          Export
        </button>
        <button className="btn btn-ghost btn-sm">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" width="13" height="13"><path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM17 14v6M14 17h6"/></svg>
          Reveal
        </button>
      </div>
      <button className="btn btn-ghost btn-sm icon-only" title="Delete">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" width="14" height="14"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/></svg>
      </button>
    </div>
  </div>
);

window.ScribeTranscriptScreen = TranscriptScreen;
