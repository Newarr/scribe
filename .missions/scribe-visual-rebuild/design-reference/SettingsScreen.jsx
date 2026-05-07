// Settings — System Settings–style grouped rows reflecting what Scribe
// actually ships in V1.0: cloud ElevenLabs transcription with Keychain
// key, ~/Scribe output folder, Calendar hints, auto-stop on silence,
// raw streams toggle. Local engine listed as "Soon".
const SettingsScreen = () => (
  <div className="screen settings">
    {/* Engine */}
    <div className="set-group">
      <div className="set-grow">
        <div className="set-grow-main">
          <div className="set-label">Engine</div>
          <div className="set-help">ElevenLabs · cloud</div>
        </div>
        <span className="set-pill set-pill-on"><span className="dot"/>Active</span>
      </div>
      <div className="set-grow">
        <div className="set-grow-main">
          <div className="set-label">On-device engine</div>
          <div className="set-help">Coming next release</div>
        </div>
        <span className="set-pill set-pill-soon">Soon</span>
      </div>
      <div className="set-grow set-grow-stack">
        <div className="set-grow-main">
          <div className="set-label">ElevenLabs API key</div>
          <div className="set-help">Stored securely in Keychain</div>
        </div>
        <input className="set-input" type="password" defaultValue="••••••••••••••••••••••••" />
      </div>
    </div>

    {/* Capture */}
    <div className="set-group">
      <div className="set-grow">
        <div className="set-grow-main">
          <div className="set-label">Auto-record on meeting apps</div>
          <div className="set-help">Zoom, Meet, Teams, FaceTime</div>
        </div>
        <Toggle on/>
      </div>
      <div className="set-grow">
        <div className="set-grow-main">
          <div className="set-label">Auto-stop on silence</div>
          <div className="set-help">After 30s · 10s countdown to cancel</div>
        </div>
        <Toggle on/>
      </div>
      <div className="set-grow">
        <div className="set-grow-main">
          <div className="set-label">Calendar hints</div>
          <div className="set-help">Use event title and attendees as hints</div>
        </div>
        <Toggle on/>
      </div>
    </div>

    {/* Shortcut */}
    <div className="set-group">
      <div className="set-grow">
        <div className="set-grow-main">
          <div className="set-label">Record now</div>
        </div>
        <div className="kbd-row"><kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>R</kbd></div>
      </div>
    </div>

    {/* Storage */}
    <div className="set-group">
      <div className="set-grow">
        <div className="set-grow-main">
          <div className="set-label">Save to</div>
          <div className="set-help">~/Scribe</div>
        </div>
        <button className="popup popup-ghost">Choose…</button>
      </div>
      <div className="set-grow">
        <div className="set-grow-main">
          <div className="set-label">Keep raw streams</div>
          <div className="set-help">Separate mic + call audio · uses more disk</div>
        </div>
        <Toggle/>
      </div>
    </div>

    {/* App */}
    <div className="set-group">
      <div className="set-grow">
        <div className="set-grow-main">
          <div className="set-label">Launch at login</div>
        </div>
        <Toggle on/>
      </div>
    </div>

    <button className="set-link">Open full settings…</button>
  </div>
);

const Toggle = ({ on: initial }) => {
  const [on, setOn] = React.useState(!!initial);
  return (
    <button className={`toggle ${on ? 'on' : ''}`} onClick={() => setOn(!on)} aria-pressed={on}>
      <span className="toggle-knob"/>
    </button>
  );
};

window.ScribeSettingsScreen = SettingsScreen;
