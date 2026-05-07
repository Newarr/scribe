// macOS-style settings window for Scribe.
// Sidebar + main pane. Shows the General panel by default; secondary
// previews of Audio + Diagnostics live in their own artboards.
const {
  Mic, Speaker, Settings, Webhook, Lock, HardDrive, Activity, Zap,
  Calendar, Eye, Refresh, FileText, Folder, ChevronRight, Plug,
} = SI;

const SidebarRow = ({ on, icon, label, count }) => (
  <div className={`side-row ${on ? "on" : ""}`}>
    <span className="ic">{icon}</span>
    <span style={{flex:1}}>{label}</span>
    {count != null && (
      <span style={{
        fontFamily: "var(--font-sans)", fontSize: 10,
        color: "rgba(255,255,255,0.55)",
        background: "rgba(255,255,255,0.08)",
        borderRadius: 99, padding: "1px 6px",
      }}>{count}</span>
    )}
  </div>
);

const Toggle = ({ on }) => <button className={`osw ${on ? "on" : ""}`}/>;

/* ============== GENERAL PANEL ============== */
const SettingsGeneral = () => (
  <div className="settings-win" data-screen-label="Settings · General">
    <div className="win-tb">
      <div className="tl-dots"><i/><i/><i/></div>
      <div className="win-title">Scribe — Settings</div>
      <div style={{width:54}}/>
    </div>
    <div className="win-body">
      <aside className="win-side">
        <SidebarRow on icon={<Settings size={14}/>}    label="General" />
        <SidebarRow    icon={<Mic size={14}/>}         label="Audio" />
        <SidebarRow    icon={<FileText size={14}/>}    label="Transcription" />
        <SidebarRow    icon={<HardDrive size={14}/>}   label="Storage" />
        <SidebarRow    icon={<Webhook size={14}/>}     label="Agents & hooks" count="3" />
        <SidebarRow    icon={<Lock size={14}/>}        label="Privacy" />
        <SidebarRow    icon={<Activity size={14}/>}    label="Diagnostics" />
        <div style={{flex:1}}/>
        <SidebarRow    icon={<Zap size={14}/>}         label="What's new" />
      </aside>
      <div className="win-pane">
        <div>
          <h2>General</h2>
          <p className="lead">How Scribe should behave when calls come and go. Keep it quiet, decide what counts as a call, and where the artifact lands.</p>
        </div>

        <div className="s-group">
          <div className="gl">CALL DETECTION</div>
          <div className="s-row">
            <div>
              <div className="lab">Auto-detect calls</div>
              <div className="help">Watch Zoom, Meet, Teams, FaceTime. Show the prompt before recording starts.</div>
            </div>
            <Toggle on/>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Match to calendar</div>
              <div className="help">Use the calendar event as the recording title and run automations for matched events.</div>
            </div>
            <Toggle on/>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Late-join window</div>
              <div className="help">Still offer to record if you join a call already in progress.</div>
            </div>
            <span className="s-select">10 min</span>
          </div>
        </div>

        <div className="s-group">
          <div className="gl">END-OF-CALL</div>
          <div className="s-row">
            <div>
              <div className="lab">Stopping-soon countdown</div>
              <div className="help">Wait this long after a call ends in case it continues informally.</div>
            </div>
            <span className="s-select">15 seconds</span>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Show saved notification</div>
              <div className="help">macOS notification with a link to the transcript.</div>
            </div>
            <Toggle on/>
          </div>
        </div>

        <div className="s-group">
          <div className="gl">SHORTCUTS</div>
          <div className="s-row">
            <div>
              <div className="lab">Open menu bar popover</div>
            </div>
            <span style={{display:"flex", gap:3}}>
              <span className="kchip">⌃</span><span className="kchip">⌥</span><span className="kchip">⌘</span><span className="kchip">S</span>
            </span>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Start manual recording</div>
            </div>
            <span style={{display:"flex", gap:3}}>
              <span className="kchip">⌥</span><span className="kchip">⌘</span><span className="kchip">R</span>
            </span>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Stop & save</div>
            </div>
            <span style={{display:"flex", gap:3}}>
              <span className="kchip">⌥</span><span className="kchip">⇧</span><span className="kchip">⌘</span><span className="kchip">.</span>
            </span>
          </div>
        </div>
      </div>
    </div>
  </div>
);

/* ============== AUDIO PANEL ============== */
const SettingsAudio = () => (
  <div className="settings-win" data-screen-label="Settings · Audio">
    <div className="win-tb">
      <div className="tl-dots"><i/><i/><i/></div>
      <div className="win-title">Scribe — Settings · Audio</div>
      <div style={{width:54}}/>
    </div>
    <div className="win-body">
      <aside className="win-side">
        <SidebarRow    icon={<Settings size={14}/>}    label="General" />
        <SidebarRow on icon={<Mic size={14}/>}         label="Audio" />
        <SidebarRow    icon={<FileText size={14}/>}    label="Transcription" />
        <SidebarRow    icon={<HardDrive size={14}/>}   label="Storage" />
        <SidebarRow    icon={<Webhook size={14}/>}     label="Agents & hooks" count="3" />
        <SidebarRow    icon={<Lock size={14}/>}        label="Privacy" />
        <SidebarRow    icon={<Activity size={14}/>}    label="Diagnostics" />
      </aside>
      <div className="win-pane">
        <div>
          <h2>Audio</h2>
          <p className="lead">Two channels in, mixed or split. Scribe watches both for silence and warns you the moment one drops out.</p>
        </div>

        <div className="s-group">
          <div className="gl">INPUT DEVICES</div>
          <div className="s-row">
            <div>
              <div className="lab">Microphone</div>
              <div className="help">The voice side. <span className="mono" style={{fontFamily:"var(--font-sans)", fontSize:10.5, color:"rgba(255,255,255,0.7)"}}>−18 dB</span> right now.</div>
            </div>
            <span className="s-select">Shure MV7+</span>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">System audio</div>
              <div className="help">The other side. Captured via ScreenCaptureKit — no virtual driver required.</div>
            </div>
            <span className="s-select">Default output</span>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Mix into a single track</div>
              <div className="help">Off keeps mic and system in separate stems for cleaner diarization.</div>
            </div>
            <Toggle/>
          </div>
        </div>

        <div className="s-group">
          <div className="gl">SILENT-CHANNEL DETECTION</div>
          <div className="s-row">
            <div>
              <div className="lab">Warn after</div>
              <div className="help">Show a popover and bar warning when one channel goes silent this long.</div>
            </div>
            <span className="s-select">8 seconds</span>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Auto-switch microphone</div>
              <div className="help">If the current mic disappears mid-call, fall back to the MacBook microphone.</div>
            </div>
            <Toggle on/>
          </div>
        </div>

        <div className="s-group">
          <div className="gl">RECORDING FORMAT</div>
          <div className="s-row">
            <div>
              <div className="lab">Audio format</div>
              <div className="help">FLAC keeps quality and size sane. MP3 if you need it for legacy tools.</div>
            </div>
            <span className="s-select">FLAC · 16-bit · 48kHz</span>
          </div>
        </div>
      </div>
    </div>
  </div>
);

/* ============== DIAGNOSTICS PANEL ============== */
const SettingsDiagnostics = () => (
  <div className="settings-win" data-screen-label="Settings · Diagnostics">
    <div className="win-tb">
      <div className="tl-dots"><i/><i/><i/></div>
      <div className="win-title">Scribe — Settings · Diagnostics</div>
      <div style={{width:54}}/>
    </div>
    <div className="win-body">
      <aside className="win-side">
        <SidebarRow    icon={<Settings size={14}/>}    label="General" />
        <SidebarRow    icon={<Mic size={14}/>}         label="Audio" />
        <SidebarRow    icon={<FileText size={14}/>}    label="Transcription" />
        <SidebarRow    icon={<HardDrive size={14}/>}   label="Storage" />
        <SidebarRow    icon={<Webhook size={14}/>}     label="Agents & hooks" count="3" />
        <SidebarRow    icon={<Lock size={14}/>}        label="Privacy" />
        <SidebarRow on icon={<Activity size={14}/>}    label="Diagnostics" />
      </aside>
      <div className="win-pane">
        <div>
          <h2>Diagnostics</h2>
          <p className="lead">Everything Scribe is doing right now. If something feels off, this is where you check before filing a bug.</p>
        </div>

        <div className="diag">
          <div className="cell">
            <span className="l">CPU</span>
            <span className="v">2.4%</span>
          </div>
          <div className="cell">
            <span className="l">MEMORY</span>
            <span className="v">186 MB</span>
          </div>
          <div className="cell">
            <span className="l">DISK BUFFER</span>
            <span className="v"><span className="ok">healthy</span></span>
          </div>
          <div className="cell">
            <span className="l">QUEUE</span>
            <span className="v">0 jobs</span>
          </div>
        </div>

        <div className="s-group">
          <div className="gl">CHANNELS</div>
          <div className="s-row">
            <div>
              <div className="lab">Microphone</div>
              <div className="help">Shure MV7+ · 48 kHz · −18 dB · 24h uptime</div>
            </div>
            <span className="indicator indicator-sent"><span className="dot"/>HEALTHY</span>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">System audio</div>
              <div className="help">ScreenCaptureKit · ENTITLEMENT OK · last drop 4d ago</div>
            </div>
            <span className="indicator indicator-sent"><span className="dot"/>HEALTHY</span>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Transcription engine</div>
              <div className="help"><span style={{fontFamily:"var(--font-sans)", fontSize:11, color:"rgba(255,255,255,0.7)"}}>whisper-large-v3</span> · GPU · last run 12m ago</div>
            </div>
            <span className="indicator indicator-sent"><span className="dot"/>HEALTHY</span>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Webhook · linear-tasks</div>
              <div className="help">Last delivery 12m ago · 2 retries this week</div>
            </div>
            <span className="indicator indicator-tx"><span className="dot"/>WARN</span>
          </div>
        </div>

        <div className="s-group">
          <div className="gl">SUPPORT</div>
          <div className="s-row">
            <div>
              <div className="lab">Export diagnostic bundle</div>
              <div className="help">Logs, recent errors, channel health. No audio or transcript content.</div>
            </div>
            <button className="b">Export</button>
          </div>
          <div className="s-row">
            <div>
              <div className="lab">Reset capture stack</div>
              <div className="help">Tears down audio graph and rebuilds. Safe during a call (briefly mutes capture).</div>
            </div>
            <button className="b">Reset</button>
          </div>
        </div>
      </div>
    </div>
  </div>
);

/* ============== SAVED NOTIFICATION TOAST ============== */
const SavedToast = () => (
  <div className="toast">
    <div className="ti">
      <span className="mb-bars" data-state="rec" style={{width:14, height:12, gap:1}}>
        <span/><span/><span/><span/>
      </span>
    </div>
    <div>
      <div className="tt">Acme Q3 sync — saved</div>
      <div className="ts">42:18 · 5,847 words · sent to <strong>linear-tasks</strong>.</div>
      <div className="tx">~/SCRIBE/2026-05-06-ACME-Q3-SYNC/</div>
    </div>
    <div className="end">
      <span className="when">now</span>
      <button className="b sm">Open</button>
    </div>
  </div>
);

window.SettingsGeneral = SettingsGeneral;
window.SettingsAudio = SettingsAudio;
window.SettingsDiagnostics = SettingsDiagnostics;
window.SavedToast = SavedToast;
