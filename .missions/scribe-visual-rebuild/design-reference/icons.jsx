// Shared inline SVG icons for the Scribe menu bar app.
// All stroke-only, currentColor, 1.5px. Sized via parent.
window.SI = (() => {
  const Icon = ({ d, size = 14, fill = "none", stroke = "currentColor", sw = 1.5, children, vb = 24 }) => (
    <svg viewBox={`0 0 ${vb} ${vb}`} width={size} height={size} fill={fill} stroke={stroke}
      strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      {d ? <path d={d}/> : children}
    </svg>
  );
  return {
    Icon,
    Mic: (p) => <Icon {...p}><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/></Icon>,
    MicOff: (p) => <Icon {...p}><path d="M3 3l18 18"/><path d="M9 9v2a3 3 0 0 0 5 2"/><path d="M15 9V6a3 3 0 0 0-6 0"/><path d="M5 11a7 7 0 0 0 11 5.5"/><path d="M12 18v3"/></Icon>,
    Speaker: (p) => <Icon {...p}><path d="M11 5L6 9H3v6h3l5 4V5z"/><path d="M16 9a4 4 0 0 1 0 6"/><path d="M19 6a8 8 0 0 1 0 12"/></Icon>,
    SpeakerOff: (p) => <Icon {...p}><path d="M11 5L6 9H3v6h3l5 4V5z"/><path d="M22 9l-6 6"/><path d="M16 9l6 6"/></Icon>,
    Pause: (p) => <Icon {...p}><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></Icon>,
    Play: (p) => <Icon {...p}><path d="M7 5v14l12-7z"/></Icon>,
    Stop: (p) => <Icon {...p} fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="1.5" stroke="none"/></Icon>,
    StopOutline: (p) => <Icon {...p}><rect x="7" y="7" width="10" height="10" rx="1.5"/></Icon>,
    Folder: (p) => <Icon {...p}><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z"/></Icon>,
    FileText: (p) => <Icon {...p}><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M9 13h6M9 17h4"/></Icon>,
    Settings: (p) => <Icon {...p}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></Icon>,
    Alert: (p) => <Icon {...p}><path d="M12 3l10 17H2L12 3z"/><path d="M12 10v4M12 17h0"/></Icon>,
    Check: (p) => <Icon {...p}><path d="M5 12l5 5L20 7"/></Icon>,
    X: (p) => <Icon {...p}><path d="M6 6l12 12M18 6L6 18"/></Icon>,
    Calendar: (p) => <Icon {...p}><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 9h18M8 3v4M16 3v4"/></Icon>,
    Clock: (p) => <Icon {...p}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></Icon>,
    Webhook: (p) => <Icon {...p}><path d="M18 16.5a2.5 2.5 0 1 1-5 0c0-1.4 1.1-2.5 2.5-2.5"/><path d="M9.7 10.3l3-5.2A3 3 0 1 1 18 7"/><path d="M5.5 12a2.5 2.5 0 1 1 4-2"/><path d="M14 14.3l3 5.2a3 3 0 1 1-5.2-3"/></Icon>,
    Apple: (p) => <Icon {...p} fill="currentColor" stroke="none"><path d="M16.4 12.3c0-2.5 2-3.7 2.1-3.8-1.2-1.7-3-2-3.6-2-1.5-.2-3 .9-3.8.9-.8 0-2-.9-3.3-.9-1.7 0-3.3 1-4.2 2.5-1.8 3.1-.5 7.7 1.3 10.3.8 1.2 1.8 2.6 3.1 2.6 1.3 0 1.7-.8 3.2-.8 1.4 0 1.9.8 3.2.8 1.3 0 2.2-1.3 3-2.5.6-.9 1.1-1.7 1.4-2.6-2-1-2.4-2.6-2.4-2.5zM14 4.6c.7-.8 1.1-1.9 1-3-1 0-2.2.7-2.9 1.5-.6.7-1.2 1.8-1 2.9 1 .1 2.2-.6 2.9-1.4z"/></Icon>,
    Wifi: (p) => <Icon {...p}><path d="M5 12.55a11 11 0 0 1 14 0M2 8.5a16 16 0 0 1 20 0M8.5 16.5a6 6 0 0 1 7 0M12 20h.01"/></Icon>,
    Battery: (p) => <Icon {...p}><rect x="2" y="8" width="18" height="9" rx="2"/><path d="M22 11v3"/><rect x="4" y="10" width="11" height="5" fill="currentColor" stroke="none"/></Icon>,
    Search: (p) => <Icon {...p}><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.5-4.5"/></Icon>,
    ChevronRight: (p) => <Icon {...p}><path d="M9 6l6 6-6 6"/></Icon>,
    ChevronDown: (p) => <Icon {...p}><path d="M6 9l6 6 6-6"/></Icon>,
    Copy: (p) => <Icon {...p}><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></Icon>,
    External: (p) => <Icon {...p}><path d="M14 4h6v6"/><path d="M20 4l-9 9"/><path d="M14 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1h5"/></Icon>,
    Refresh: (p) => <Icon {...p}><path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/></Icon>,
    Plug: (p) => <Icon {...p}><path d="M9 2v6M15 2v6"/><path d="M6 8h12v4a6 6 0 0 1-12 0V8z"/><path d="M12 18v4"/></Icon>,
    Link: (p) => <Icon {...p}><path d="M10 14a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1"/><path d="M14 10a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"/></Icon>,
    Lock: (p) => <Icon {...p}><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></Icon>,
    HardDrive: (p) => <Icon {...p}><rect x="2" y="14" width="20" height="6" rx="1.5"/><path d="M5 14l3-9h8l3 9"/><circle cx="6.5" cy="17" r=".5" fill="currentColor"/></Icon>,
    Zap: (p) => <Icon {...p}><path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z"/></Icon>,
    Activity: (p) => <Icon {...p}><path d="M3 12h4l3-9 4 18 3-9h4"/></Icon>,
    Eye: (p) => <Icon {...p}><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></Icon>,
    Send: (p) => <Icon {...p}><path d="M22 3L11 14"/><path d="M22 3l-7 18-4-8-8-4 19-6z"/></Icon>,
    Pencil: (p) => <Icon {...p}><path d="M14 4l6 6L8 22H2v-6L14 4z"/></Icon>,
    Search2: (p) => <Icon {...p}><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.5-4.5"/></Icon>,
    Drag: (p) => <Icon {...p}><circle cx="9" cy="6" r="1.2" fill="currentColor"/><circle cx="9" cy="12" r="1.2" fill="currentColor"/><circle cx="9" cy="18" r="1.2" fill="currentColor"/><circle cx="15" cy="6" r="1.2" fill="currentColor"/><circle cx="15" cy="12" r="1.2" fill="currentColor"/><circle cx="15" cy="18" r="1.2" fill="currentColor"/></Icon>,
    Folders: (p) => <Icon {...p}><path d="M2 7a2 2 0 0 1 2-2h3l2 2h6a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7z"/><path d="M6 17v.5a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V11a2 2 0 0 0-2-2h-2"/></Icon>,
  };
})();
