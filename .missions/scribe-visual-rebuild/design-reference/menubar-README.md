# Menu bar app UI Kit

The Mac menu bar popover for Scribe. Opens from the menu bar icon, shows recent calls, lets you tag, drag, send to agent.

## Screens (toggle via the segmented control at the top)
1. `Idle` — quiet state, "no call detected" empty
2. `Recording` — live call in progress, waveform, elapsed timer
3. `Transcript` — recent call selected, full transcript visible, action row
4. `Settings` — webhook + agent endpoints config

## Files
- `index.html` — popover frame + screen switcher
- `Popover.jsx` — frame chrome (titlebar with mark, status row)
- `IdleScreen.jsx`
- `RecordingScreen.jsx`
- `TranscriptScreen.jsx`
- `SettingsScreen.jsx`
