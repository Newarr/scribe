// Scribe popover variants. Each is a self-contained popover element
// that can be dropped into a desktop frame inside the design canvas.
const {
  Mic, MicOff, Speaker, SpeakerOff, Pause, Play, Stop, Folder, FileText,
  Settings, Alert, Check, X, Calendar, Clock, Webhook, Refresh,
  Plug, Lock, HardDrive, Zap, Activity, Eye, Send, Copy, External,
  ChevronRight, ChevronDown, Search2, Drag, Folders,
} = SI;

/* ---------- Header ---------- */
const PopHead = ({ statusKind = "live", statusLabel, right = null }) => (
  <div className="pop-h">
    <div className="pop-brand">
      <svg viewBox="0 0 140 32" width="64" height="14" fill="none" aria-label="scribe">
        <rect x="0"  y="10" width="2.5" height="12" rx="1" fill="currentColor"/>
        <rect x="5"  y="6"  width="2.5" height="20" rx="1" fill="currentColor"/>
        <rect x="10" y="2"  width="2.5" height="28" rx="1" fill="currentColor"/>
        <rect x="15" y="6"  width="2.5" height="20" rx="1" fill="currentColor"/>
        <rect x="20" y="10" width="2.5" height="12" rx="1" fill="currentColor"/>
        <text x="32" y="23" fontFamily="Inter, -apple-system, sans-serif" fontSize="20" fontWeight="600" letterSpacing="-0.04em" fill="currentColor">scribe</text>
      </svg>
    </div>
    <div className="pop-headmeta">
      {statusLabel && (
        <span className={`indicator indicator-${statusKind}`}>
          <span className="dot"/>{statusLabel}
        </span>
      )}
      {right}
      <button className="iconbtn" title="Settings"><Settings size={13}/></button>
    </div>
  </div>
);

/* ---------- Waveform ---------- */
const Waveform = ({ count = 64, warn = false, paused = false }) => {
  // Pre-seeded amplitudes so it renders nicely without runtime jitter
  const seeds = React.useMemo(() => {
    const arr = [];
    for (let i = 0; i < count; i++) {
      const t = i / count;
      const env = Math.sin(t * Math.PI) * 0.85 + 0.15;
      const noise = 0.55 + 0.45 * Math.sin(i * 0.7) * Math.cos(i * 0.3);
      arr.push(Math.max(0.18, Math.min(1, env * noise)));
    }
    return arr;
  }, [count]);
  return (
    <div className={`wf ${warn ? "warn" : ""}`}>
      {seeds.map((h, i) => (
        <span key={i} className={`bar ${warn && i % 3 === 1 ? "dim" : ""}`}
          style={{
            "--high": h,
            "--low": Math.max(0.12, h * 0.18),
            "--dur": `${700 + (i % 5) * 60}ms`,
            "--delay": `${(i % 11) * 40}ms`,
            ...(paused ? { animationPlayState: "paused", transform: `scaleY(${h * 0.6})` } : {}),
          }}/>
      ))}
    </div>
  );
};

/* =====================================================================
   1. ACTIVE RECORDING — HEALTHY
   ===================================================================== */
const PopRecordingHealthy = () => (
  <div className="pop">
    <PopHead statusKind="live" statusLabel="REC · 04:21"/>
    <div className="pop-body">
      <div className="cap">
        <div className="cap-head">
          <div className="cap-id">
            <span className="title">Acme Q3 sync</span>
            <span className="sub">ZOOM · 4 PARTICIPANTS</span>
          </div>
          <div className="cap-elapsed">04:21<span className="ms">.6</span></div>
        </div>
        <Waveform />
        <div className="health">
          <div className="ch" style={{"--lv":"68%"}}>
            <Mic size={13}/>
            <span className="lbl">MIC</span>
            <span className="level"/>
            <span className="val">−18 dB</span>
          </div>
          <div className="ch" style={{"--lv":"54%"}}>
            <Speaker size={13}/>
            <span className="lbl">SYS</span>
            <span className="level"/>
            <span className="val">−22 dB</span>
          </div>
        </div>
      </div>

      <div className="outcome">
        <span className="icn"><FileText size={13}/></span>
        <div>
          <div>When this ends → <strong>transcript + audio saved</strong>, webhook fires.</div>
          <span className="path">~/Scribe/2026-05-06-acme-q3-sync/</span>
        </div>
      </div>

      <div className="acts">
        <button className="b"><Pause size={11}/>Pause</button>
        <button className="b primary grow2"><Stop size={11}/>Stop & save</button>
        <button className="b ghost" title="Open folder"><Folder size={13}/></button>
      </div>
    </div>
  </div>
);

/* =====================================================================
   2. ACTIVE RECORDING — WARNING
   ===================================================================== */
const PopRecordingWarn = () => (
  <div className="pop">
    <PopHead statusKind="failed" statusLabel="REC · WARNING"/>
    <div className="pop-body">
      <div className="cap warn">
        <div className="cap-head">
          <div className="cap-id">
            <span className="title">Acme Q3 sync</span>
            <span className="sub">ZOOM · 4 PARTICIPANTS</span>
          </div>
          <div className="cap-elapsed" style={{color:"oklch(0.85 0.12 75)"}}>
            12:48<span className="ms">.2</span>
          </div>
        </div>
        <Waveform warn />
        <div className="health">
          <div className="ch" style={{"--lv":"62%"}}>
            <Mic size={13}/>
            <span className="lbl">MIC</span>
            <span className="level"/>
            <span className="val">−19 dB</span>
          </div>
          <div className="ch silent">
            <SpeakerOff size={13}/>
            <span className="lbl">SYS</span>
            <span className="level"/>
            <span className="val">silent</span>
          </div>
        </div>
      </div>

      <div className="warn-strip">
        <span className="i"><Alert size={16}/></span>
        <div className="m">
          <div className="t">System audio silent for 8s.</div>
          <div className="s">Recording continues. Other participants may be missing from the transcript.</div>
          <div className="meta">CHECK INPUT · ScreenCaptureKit</div>
        </div>
      </div>

      <div className="acts">
        <button className="b warn"><Refresh size={11}/>Repair input</button>
        <button className="b ghost"><Pause size={11}/>Pause</button>
        <button className="b"><Stop size={11}/>Stop & save</button>
      </div>
    </div>
  </div>
);

/* =====================================================================
   3. MEETING DETECTED PROMPT (default + late-join variant)
   ===================================================================== */
const ZoomGlyph = () => (
  <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden>
    <rect x="2" y="6" width="16" height="12" rx="3" fill="oklch(0.55 0.18 250)"/>
    <path d="M22 8l-4 3v2l4 3z" fill="oklch(0.55 0.18 250)"/>
  </svg>
);
const MeetGlyph = () => (
  <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden>
    <rect x="3" y="6" width="14" height="12" rx="2.5" fill="oklch(0.55 0.18 145)"/>
    <path d="M21 8l-4 3v2l4 3z" fill="oklch(0.65 0.18 75)"/>
  </svg>
);

const PopDetected = () => (
  <div className="pop">
    <PopHead statusKind="ready" statusLabel="DETECTED"/>
    <div className="pop-body">
      <div className="detected">
        <div className="detect-head">
          <div className="app-glyph"><ZoomGlyph/></div>
          <div className="detect-meta">
            <div className="title">Acme Q3 sync</div>
            <div className="sub">ZOOM · 4 PARTICIPANTS · STARTED 00:14</div>
          </div>
        </div>
        <div className="cal-match">
          <div className="barv"/>
          <div className="lines">
            <div className="l1">Acme · Q3 review</div>
            <div className="l2">14:00 — 14:30 · CALENDAR MATCH</div>
          </div>
          <Check size={14} stroke="oklch(0.78 0.16 145)"/>
        </div>
      </div>

      <div className="outcome">
        <span className="icn"><FileText size={13}/></span>
        <div>
          When this ends → <strong>transcript + audio saved</strong>, sent to <strong>linear-tasks</strong>.
        </div>
      </div>

      <div className="acts">
        <button className="b primary grow2"><span className="statdot live"/>Record now</button>
        <button className="b">Skip</button>
      </div>

      <div className="acts" style={{marginTop:"-2px"}}>
        <button className="b ghost sm" style={{flex:"1", justifyContent:"flex-start"}}>
          Always for this calendar event <ChevronRight size={11} style={{marginLeft:"auto"}}/>
        </button>
      </div>
    </div>
  </div>
);

const PopDetectedLateJoin = () => (
  <div className="pop">
    <PopHead statusKind="ready" statusLabel="LATE JOIN"/>
    <div className="pop-body">
      <div className="detected">
        <div className="detect-head">
          <div className="app-glyph"><MeetGlyph/></div>
          <div className="detect-meta">
            <div className="title">Onboarding — J. Patel</div>
            <div className="sub">GOOGLE MEET · 2 PARTICIPANTS</div>
          </div>
        </div>
        <div className="late-strip">
          <Clock size={13}/>
          <div style={{flex:1}}>Already in progress.</div>
          <span className="x">+06:42</span>
        </div>
      </div>

      <div className="outcome">
        <span className="icn"><FileText size={13}/></span>
        <div>
          Recording starts now. Earlier audio <strong>can&rsquo;t be recovered</strong>.
        </div>
      </div>

      <div className="acts">
        <button className="b primary grow2"><span className="statdot live"/>Record from now</button>
        <button className="b">Skip</button>
      </div>
    </div>
  </div>
);

/* =====================================================================
   4. STOPPING SOON HUD (post-call countdown)
   ===================================================================== */
const HudStoppingSoon = () => (
  <div className="hud">
    <div className="hud-head">
      <span className="statdot live"/>
      <span>CALL ENDED · SCRIBE STILL RECORDING</span>
    </div>
    <div className="hud-count">12<span className="unit">s</span></div>
    <div className="hud-text">
      Stopping in case the conversation continues.
      <br/>You&rsquo;ve added <strong>00:14</strong> after Zoom hung up.
    </div>
    <div className="hud-bar"><i style={{transform:"scaleX(0.4)"}}/></div>
    <div className="hud-acts">
      <button className="b"><Plug size={11}/>Keep recording</button>
      <button className="b primary"><Stop size={11}/>Stop now</button>
    </div>
  </div>
);

/* =====================================================================
   5. FINALIZING / SAVED / FAILED
   ===================================================================== */
const PopFinalizing = () => (
  <div className="pop">
    <PopHead statusKind="tx" statusLabel="FINALIZING"/>
    <div className="fin">
      <div className="fin-glyph spin"/>
      <div className="fin-h">Saving recording…</div>
      <div className="fin-sub">Transcribing 42:18 of audio. Audio file is already on disk — closing now is safe.</div>
      <dl className="kv" style={{marginTop:"4px"}}>
        <dt>AUDIO</dt><dd className="path"><Check size={11} stroke="oklch(0.78 0.16 145)"/> 38.2 MB · saved</dd>
        <dt>TX</dt><dd className="path">whisper-large-v3 · 64% · 0:18 left</dd>
        <dt>HOOKS</dt><dd className="path">linear-tasks · queued</dd>
      </dl>
    </div>
  </div>
);

const PopSaved = () => (
  <div className="pop">
    <PopHead statusKind="sent" statusLabel="SAVED"/>
    <div className="fin">
      <div className="fin-glyph ok"><Check size={20}/></div>
      <div className="fin-h">Acme Q3 sync</div>
      <div className="fin-sub">42 minutes · transcript and audio on disk · webhook fired.</div>
      <dl className="kv">
        <dt>DURATION</dt><dd>42:18</dd>
        <dt>WORDS</dt><dd>5,847 across 4 speakers</dd>
        <dt>FILE</dt>
        <dd className="path">~/Scribe/2026-05-06-acme-q3-sync/</dd>
      </dl>
      <div className="acts" style={{marginTop:"2px"}}>
        <button className="b primary grow2"><FileText size={11}/>Open transcript</button>
        <button className="b"><Folder size={11}/>Folder</button>
        <button className="b ghost"><Send size={11}/></button>
      </div>
    </div>
  </div>
);

const PopFailed = () => (
  <div className="pop">
    <PopHead statusKind="failed" statusLabel="FAILED"/>
    <div className="fin">
      <div className="fin-glyph fail"><Alert size={18}/></div>
      <div className="fin-h fail-h">Audio is intact.</div>
      <div className="fin-sub">
        Transcription failed after 12 minutes. Your <strong>42:18 recording</strong> is still on disk and can be retried any time.
      </div>
      <dl className="kv">
        <dt>AUDIO</dt><dd className="path"><Check size={11} stroke="oklch(0.78 0.16 145)"/> 38.2 MB · acme-q3.wav</dd>
        <dt>FAIL</dt><dd>whisper-large-v3 · timeout at 12:04</dd>
        <dt>FILE</dt><dd className="path">~/Scribe/2026-05-06-acme-q3-sync/</dd>
      </dl>
      <div className="acts" style={{marginTop:"2px"}}>
        <button className="b primary grow2"><Refresh size={11}/>Retry transcription</button>
        <button className="b"><Folder size={11}/>Open audio</button>
      </div>
    </div>
  </div>
);

/* =====================================================================
   6. RECENTS POPOVER (idle)
   ===================================================================== */
const RecRow = ({ title, when, dur, status, src }) => {
  const dot = (
    <span className={`statdot ${status}`}/>
  );
  const statusLabel = {
    ready:  "READY",
    sent:   "SENT · linear",
    tx:     "TRANSCRIBING",
    failed: "FAILED",
  }[status];
  return (
    <div className="rec-item">
      <span className="glyph">{src}</span>
      <div className="body">
        <span className="ttl">{title}</span>
        <span className="meta">
          {dot}<span>{statusLabel}</span>
          <span className="sep">·</span>
          <span>{when}</span>
        </span>
      </div>
      <div className="end">
        <span className="dur">{dur}</span>
        <span className="icns">
          <button className="iconbtn" title="Open transcript"><FileText size={12}/></button>
          <button className="iconbtn" title="Open folder"><Folder size={12}/></button>
        </span>
      </div>
    </div>
  );
};

const PopRecents = () => (
  <div className="pop">
    <PopHead statusKind="idle" statusLabel="IDLE"/>
    <div className="pop-body tight">
      <div className="outcome" style={{padding:"8px 10px"}}>
        <span className="icn"><Eye size={13}/></span>
        <div>Watching for calls. Next event: <strong>Acme · Q3 review</strong> in 18m.</div>
      </div>

      <div className="sect-l">RECENT</div>
      <div className="recents">
        <RecRow title="Onboarding — J. Patel" when="14m ago"   dur="42:18" status="tx"     src="ZM"/>
        <RecRow title="Vendor call — Stripe"  when="2h ago"    dur="18:04" status="ready"  src="MT"/>
        <RecRow title="Weekly standup"        when="Mon 09:30" dur="26:11" status="sent"   src="GM"/>
        <RecRow title="Design review"         when="Mon 14:00" dur="51:32" status="sent"   src="ZM"/>
        <RecRow title="1:1 — D. Chen"         when="Fri 16:00" dur="22:48" status="failed" src="ZM"/>
      </div>

      <div className="acts" style={{marginTop:"4px"}}>
        <button className="b ghost sm" style={{flex:1, justifyContent:"flex-start"}}>
          <Folders size={11}/>Open folder
        </button>
        <span className="kchip">⌥</span>
        <span className="kchip">⌘</span>
        <span className="kchip">R</span>
        <span style={{fontSize:11, color:"rgba(255,255,255,0.45)", marginLeft:4}}>start manual</span>
      </div>
    </div>
  </div>
);

/* =====================================================================
   7. SETUP REQUIRED POPOVER
   ===================================================================== */
const SetupRow = ({ ok, icon, label, help, action }) => (
  <div className={`setup-row ${ok ? "ok" : "bad"}`}>
    <span className="check">{ok ? <Check size={11}/> : <X size={11}/>}</span>
    <div className="body">
      <span className="lbl">{label}</span>
      <span className="help">{help}</span>
    </div>
    {ok ? (
      <span className="indicator indicator-sent" style={{fontSize:9.5}}><span className="dot"/>READY</span>
    ) : (
      <button className="b sm">{action}</button>
    )}
  </div>
);

const PopSetup = () => (
  <div className="pop">
    <PopHead statusKind="failed" statusLabel="SETUP REQUIRED"/>
    <div className="pop-body">
      <div className="outcome" style={{padding:"10px 12px"}}>
        <span className="icn"><Alert size={13} stroke="oklch(0.80 0.14 75)"/></span>
        <div>
          <strong>3 of 5</strong> ready. Scribe needs these before it can record.
        </div>
      </div>

      <div className="sect-l">PERMISSIONS</div>
      <div className="s-group" style={{background:"transparent", border:"1px solid rgba(255,255,255,0.06)"}}>
        <SetupRow ok={true}  label="Microphone" help="MacBook Pro Microphone" action="Grant" />
        <SetupRow ok={false} label="Screen & system audio"
          help={<><span className="mono">com.apple.ScreenCapture</span> not granted. Required to capture the other side of calls.</>}
          action="Open settings" />
        <SetupRow ok={true}  label="Calendar" help="iCloud · jordan@…" action="Grant" />
      </div>

      <div className="sect-l">DATA</div>
      <div className="s-group" style={{background:"transparent", border:"1px solid rgba(255,255,255,0.06)"}}>
        <SetupRow ok={true}  label="Output folder" help="~/Scribe — 84 GB free" action="Pick" />
        <SetupRow ok={false} label="Transcription engine"
          help="No engine configured. Pick local Whisper or paste an OpenAI key."
          action="Configure" />
      </div>

      <div className="acts">
        <button className="b primary grow2">Fix all</button>
        <button className="b ghost">Skip for now</button>
      </div>
    </div>
  </div>
);

/* =====================================================================
   8. INLINE WARNING (mini popover variant) — extracted for canvas
   ===================================================================== */
const PopMicMissing = () => (
  <div className="pop">
    <PopHead statusKind="failed" statusLabel="WARNING"/>
    <div className="pop-body">
      <div className="cap warn">
        <div className="cap-head">
          <div className="cap-id">
            <span className="title">Vendor call — Stripe</span>
            <span className="sub">FACETIME · 2 PARTICIPANTS</span>
          </div>
          <div className="cap-elapsed" style={{color:"oklch(0.85 0.12 75)"}}>03:02<span className="ms">.4</span></div>
        </div>
        <Waveform warn paused/>
        <div className="health">
          <div className="ch silent">
            <MicOff size={13}/>
            <span className="lbl">MIC</span>
            <span className="level"/>
            <span className="val">missing</span>
          </div>
          <div className="ch" style={{"--lv":"58%"}}>
            <Speaker size={13}/>
            <span className="lbl">SYS</span>
            <span className="level"/>
            <span className="val">−21 dB</span>
          </div>
        </div>
      </div>

      <div className="warn-strip">
        <span className="i"><MicOff size={15}/></span>
        <div className="m">
          <div className="t">Mic input missing.</div>
          <div className="s">Your voice isn&rsquo;t being captured. The other side will still be recorded.</div>
          <div className="meta">DEVICE UNPLUGGED · External USB Mic</div>
        </div>
      </div>

      <div className="acts">
        <button className="b warn"><Refresh size={11}/>Switch to MacBook mic</button>
        <button className="b ghost"><Settings size={11}/></button>
        <button className="b"><Stop size={11}/>Stop</button>
      </div>
    </div>
  </div>
);

window.PopRecordingHealthy = PopRecordingHealthy;
window.PopRecordingWarn = PopRecordingWarn;
window.PopDetected = PopDetected;
window.PopDetectedLateJoin = PopDetectedLateJoin;
window.HudStoppingSoon = HudStoppingSoon;
window.PopFinalizing = PopFinalizing;
window.PopSaved = PopSaved;
window.PopFailed = PopFailed;
window.PopRecents = PopRecents;
window.PopSetup = PopSetup;
window.PopMicMissing = PopMicMissing;
