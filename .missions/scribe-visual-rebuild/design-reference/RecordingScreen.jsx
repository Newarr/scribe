// Live recording — the wave IS the screen. Everything else recedes.
// Post-call processing only (no live transcript). Honors the "wavy directional" feedback:
// big breathing waveform, minimal chrome, single source line, single timer, single action.
const RecordingScreen = ({ elapsed = '04:21', source = 'Acme Q3 sync', via = 'Zoom' }) => {
  // 56 bars, varied envelope so it reads as natural speech, not a clock pattern.
  const BARS = 56;
  const heights = React.useMemo(
    () => Array.from({length: BARS}, (_, i) => {
      const env = Math.sin((i / BARS) * Math.PI);                 // belly in the middle
      const grain = Math.abs(Math.sin(i * 0.9) + Math.cos(i * 1.7) * 0.7);
      return 0.18 + env * 0.55 + grain * 0.28;                    // 0.18 .. ~1.0
    }),
    []
  );

  return (
    <div className="screen rec-screen">
      {/* Source + timer share one line — the only thing above the wave */}
      <div className="rec-meta">
        <div className="rec-source">
          <span className="indicator indicator-live"><span className="dot"/></span>
          <span className="rec-title">{source}</span>
          <span className="rec-via">via {via}</span>
        </div>
        <div className="rec-elapsed">{elapsed}</div>
      </div>

      {/* The hero wave */}
      <div className="wave-stage" aria-hidden>
        {heights.map((h, i) => (
          <span key={i}
                className="wave-bar"
                style={{
                  '--h': h,
                  '--i': i,
                  animationDelay: `${(i * 60) % 1800 - 900}ms`,
                }}/>
        ))}
      </div>

      {/* Audio level + actions */}
      <div className="rec-foot">
        <div className="rec-intent">
          Recording locally · saved when you stop
        </div>
        <div className="rec-actions">
          <button className="btn btn-ghost btn-sm">Pause</button>
          <button className="btn btn-secondary btn-sm">Stop</button>
        </div>
      </div>
    </div>
  );
};

window.ScribeRecordingScreen = RecordingScreen;
