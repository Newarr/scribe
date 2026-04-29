# Slice 6 — Calendar Enrichment Full Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`.

**Goal:** Replace slice 3's point-in-time `CalendarLookup` with a rolling-cache `CalendarWatcher` actor that polls EventKit every 60s, refreshes on wake-from-sleep, and serves cached lookups to the rest of the app. The detection layer's start prompt gets enriched copy ("Start recording 'Acme Weekly'?") when an overlapping event is in cache, falling back to "Start recording <app>?" when there's nothing.

**Why now:** Slice 5 light's start prompt is generic ("Start recording Zoom?"). When the user has a calendar entry overlapping the prompt, showing the meeting title makes the choice obvious. Spec lines 167-168 explicitly call this out. Slice 3's lookup runs only at session start, so the detection layer (which fires before session start) couldn't use it.

**Architecture:**
- **`CalendarWatcher`** actor — owns an in-memory `CalendarCache` of events in [now-15m, now+24h], refreshes via `EKEventStore.events(matching:)`, exposes `eventOverlapping(_:Date)` for sync lookups (no awaiting EventKit during the prompt path).
- Polling: `Task` loop sleeping 60s between refreshes. Cancellable.
- Wake handling: subscribes to `NSWorkspace.didWakeNotification` and forces an immediate refresh.
- **`StartPromptCoordinator`** modified to take an optional `CalendarEvent?` and stamp the title into the alert.
- **AppDelegate** holds a single `CalendarWatcher` instance, kicked off in `applicationDidFinishLaunching` after permission is granted; queries it from both `handleDetectionCandidate` (for prompt enrichment) and `startRecording` (for session-start metadata).

**Tech stack:** EventKit (already used in slice 3), `NSWorkspace` notifications, `Task.sleep` for the poll loop. No new third-party deps.

**Spec sections covered:** lines 77-88 (Calendar enrichment), 167 (calendar-enriched start prompt), `decision_calendar_enrichment_only` (still respected — calendar never triggers a session, never blocks one).

---

## File structure

```
Sources/TranscriberCore/Calendar/
  CalendarCache.swift       # NEW: in-memory cache of recent events
  CalendarWatcher.swift     # NEW: actor wrapping CalendarLookup with polling

Tests/TranscriberCoreTests/Calendar/
  CalendarCacheTests.swift
  CalendarWatcherTests.swift

TranscriberApp/TranscriberApp/
  AppDelegate.swift              # MODIFY: instantiate watcher, query for prompt
  StartPromptCoordinator.swift   # MODIFY: accept optional CalendarEvent for title
```

`CalendarLookup` from slice 3 stays as the underlying sync API; the watcher composes it.

---

## Tasks

**T1. CalendarCache** — pure value type. `events: [CalendarEvent]`, plus `eventOverlapping(_ date: Date) -> CalendarEvent?` and `eventClosestTo(_ date: Date, within: TimeInterval) -> CalendarEvent?`. Drop entries older than `now-15m` on every refresh. Tests: empty cache returns nil, overlap finds correct event, closest-within picks nearest, outside-window rejects.

**T2. CalendarWatcher actor** — holds a `CalendarCache`, owns a `Task` running a poll loop (sleep 60s, refresh, repeat). `start()` kicks the loop, `stop()` cancels it. `refreshNow()` for wake-handling. `eventOverlapping(_:)` is sync over the cache (not over EKEventStore — that's why it's a cache).

Constructor takes a `lookup: CalendarLookupProtocol` so tests can inject a fake. Real implementation uses `CalendarLookup` from slice 3 wrapped in a small protocol.

Tests:
- `start()` populates cache from injected fake lookup
- `refreshNow()` re-queries the lookup
- Cache returns most-recent event after refresh
- `stop()` cancels the poll Task
- Wake notification triggers refresh (verify via fake counter)

**T3. AppDelegate integration** — replace direct `CalendarLookup` use with `CalendarWatcher`. Watcher started after `requestAccess()` resolves. `handleDetectionCandidate` queries `watcher.eventOverlapping(Date())` and passes the result to the coordinator. `startRecording` continues to use the same call.

**T4. StartPromptCoordinator update** — `prompt(for app: MeetingApp, event: CalendarEvent?) -> Choice`. If event is non-nil, message reads "Start recording '<event title>'?" otherwise "Start recording <app display name>?".

**T5. Acceptance + codex + merge + tag**.

---

## Definition of done

- [ ] Watcher polls every 60s in the background; CI doesn't slow down (poll Task injectable for tests)
- [ ] Wake from sleep refreshes the cache on next foreground
- [ ] Detection prompt shows event title when an overlapping event exists in cache
- [ ] `startRecording` still works without calendar permission (cache is empty, lookups return nil — no blocking)
- [ ] All XCTest tests pass; CI green; codex review clean
- [ ] No event content leaks into Console.app logs (only event count + match-or-no-match flags)
