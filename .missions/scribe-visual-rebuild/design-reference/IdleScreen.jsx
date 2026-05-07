// Idle — a single calendar hint and a tight list of recents.
// One line of meta per row max. No status pills on history.
const IdleScreen = ({ recentCalls = [], nextCall }) => (
  <div className="screen">
    {nextCall ? (
      <div className="up-next">
        <div className="up-next-label">Up next</div>
        <div className="up-next-row">
          <div className="up-next-title">{nextCall.title}</div>
          <div className="up-next-when">{nextCall.when}</div>
        </div>
      </div>
    ) : (
      <div className="empty">
        <div className="empty-pulse" aria-hidden><span/><span/><span/></div>
        <div className="empty-title">Listening.</div>
        <div className="empty-sub">Auto-records Zoom, Meet, Teams, FaceTime.</div>
      </div>
    )}

    <div className="section-label">Recent</div>
    <div className="rows">
      {recentCalls.map((c, i) => (
        <div className="row" key={i}>
          <div className="row-main">
            <div className="row-title">{c.title}</div>
            <div className="row-meta">{c.when} · {c.duration}</div>
          </div>
          <div className="row-end">
            <span className="row-arrow" aria-hidden>→</span>
          </div>
        </div>
      ))}
    </div>
  </div>
);

window.ScribeIdleScreen = IdleScreen;
