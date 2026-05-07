// Mac menu bar — exact pixel real-size strip + Scribe icon.
// Renders as a 24px-tall NSMenuBar fragment with the right-side
// system items (control center, wifi, battery, time) + Scribe.
const { Apple, Wifi, Battery, Search } = SI;

const MacMenuBar = ({ state = "idle", counter = null, dotColor }) => {
  const dotClass = {
    idle: null,
    setup: "warn",
    detected: "success",
    rec: null,            // rust dot is the default --live-dot
    warn: "warn",
    stop: "warn",
    final: null,
    saved: "success",
    failed: "danger",
  }[state];

  const showDot = ["setup","detected","rec","warn","stop","final","saved","failed"].includes(state);
  const live = state === "rec" || state === "warn" || state === "stop" || state === "final";

  // The label that follows the icon (if any). The brief says counter
  // appears live; a tiny status hint appears for non-rec edge states.
  const inlineLabel = (() => {
    if (state === "rec" && counter)  return <span className="mb-counter">{counter}</span>;
    if (state === "warn" && counter) return <span className="mb-counter warn">{counter}</span>;
    if (state === "stop" && counter) return <span className="mb-counter warn">{counter}</span>;
    if (state === "final")           return <span className="mb-counter">saving…</span>;
    if (state === "saved")           return <span className="mb-counter success">saved</span>;
    if (state === "failed")          return <span className="mb-counter" style={{color:"oklch(0.78 0.16 30)"}}>failed</span>;
    return null;
  })();

  return (
    <div className="macbar">
      <div className="macbar-left">
        <span className="apple"><Apple size={14}/></span>
        <span className="macbar-app">Safari</span>
        <span className="macbar-menu">File</span>
        <span className="macbar-menu">Edit</span>
        <span className="macbar-menu">View</span>
        <span className="macbar-menu">History</span>
        <span className="macbar-menu">Bookmarks</span>
        <span className="macbar-menu">Window</span>
        <span className="macbar-menu">Help</span>
      </div>
      <div className="macbar-right">
        <span className="icn"><Wifi size={14}/></span>
        <span className="icn"><Battery size={14}/></span>
        <span className="icn"><Search size={14}/></span>
        <span className={`scribe-mb ${state === "rec" || state === "warn" ? "active" : ""}`}>
          <span className="mb-mark">
            <span className={`mb-bars ${live ? "live" : ""}`} data-state={state}>
              <span/><span/><span/><span/>
            </span>
            {showDot && <span className={`mb-dot ${dotClass||""}`}/>}
          </span>
          {inlineLabel}
        </span>
        <span className="clock">14:23</span>
      </div>
    </div>
  );
};

window.MacMenuBar = MacMenuBar;
