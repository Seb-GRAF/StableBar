# Shared providers and native data

Define a provider once and reference it from several widgets. StableBar keeps one sampler or command process for all enabled consumers; each widget can use a different layout, popup, display and style. Provider output uses the same `text`, `fields`, `values`, `lists` and other fields as script output.

```json
{
  "providers": {
    "machine": { "type": "system", "interval": 2 },
    "music": {
      "type": "stream",
      "command": "\"$CONFIG_DIR/music-events\"",
      "interval": 2,
      "whenVisible": true
    }
  },
  "widgets": [
    {
      "id": "cpu", "type": "provider", "provider": "machine", "position": "right",
      "layout": { "type": "field", "field": "cpu" }
    },
    {
      "id": "memory", "type": "provider", "provider": "machine", "position": "right",
      "layout": { "type": "progress", "source": "memory", "style": { "width": 60 } }
    },
    {
      "id": "song", "type": "provider", "provider": "music", "position": "left"
    }
  ]
}
```

Provider `type` is `command`, `stream`, `system`, `network`, `battery`, `audio` or `calendar`. `command` and `stream` require a shell `command`. `interval` defaults to 5 seconds: the polling interval for commands, `system` and `network`, and for `calendar` until it has access; the first reconnect delay for streams; and for `audio` and `battery`, which update when macOS reports a change, the first retry delay after a failure. That first delay is `interval`, or 1 second if `interval` is shorter. `timeout` defaults to 10 seconds and applies to command providers; streams remain running until they exit, fail, suspend or stop. Provider intervals and timeouts must be positive and finite.

A widget with `type` set to `system`, `network`, `battery`, `audio` or `calendar` uses the provider of that name. Without a definition in `providers`, it is a native provider of that type with default settings, shared by every widget that names it. An implicit `system` provider uses a 2-second interval and lists 5 apps when a consumer enables Essentials details. Define a provider with the same name to change its interval or other settings. `{ "id": "power", "type": "battery", "position": "right" }` is enough for a battery widget.

Provider `environment` overlays the top-level environment. `NAME` is the provider name and `CONFIG_DIR` remains the main configuration directory. The environment of a consuming widget applies to that widget's actions, not the shared update process. Add `events` to a provider or consuming widget to request updates; one event refreshes a shared provider once. An explicit refresh restarts a stream's process with the new event payload, and restarts the listener of a push source such as `battery`, which then reads its current state again.

A stream writes one complete JSON object per line, including `text`, and flushes stdout after each update. Empty lines are ignored; the final line may omit its newline. Streaming output represents current state: when updates arrive faster than the UI consumes them, only the newest pending update is retained. Each line is limited to 1 MiB; stderr retains its latest 16 KiB. Malformed output stops the process and retains the last good value. Clean exits and failures reconnect with exponential backoff, capped at five minutes or the configured interval if longer. Ten seconds of successful streaming resets the failure streak.

Set `whenVisible` to `true` to suspend a provider when none of its consumers is visible on any display, including widgets moved to overflow. Removing or disabling the last consuming widget stops the provider. System sleep suspends scripts and providers; resuming preserves the last output and graph history, and starts a fresh update with `SENDER=resume`. A suspended or stopped `audio` or `battery` provider removes its macOS listeners. A provider whose events a widget subscribes to stays running; see [Script events](create-a-widget.md#script-events).

Native providers use public macOS APIs and launch no shell commands:

| Type | Output contract |
| --- | --- |
| `system` | `value` and `values.cpu`: CPU fraction, made of `values.cpuUser` for programs and `values.cpuSystem` for macOS itself; `values.memory`: used-memory fraction; `values.memoryUsed` and `values.memoryTotal`: bytes. `fields.cpu`, `fields.cpuUser`, `fields.cpuSystem` and `fields.memory` are whole percentages; `fields.memoryUsed`, `fields.memoryCompressed` and `fields.swap` are sizes such as `18.2 GB`. `fields.pressure`: macOS's memory pressure, `normal`, `warning` or `critical`; `fields.thermal`: `nominal`, `fair`, `serious` or `critical`, rising as the Mac slows itself down to cool off; `fields.load`: the 1, 5 and 15 minute load averages; `fields.uptime`: the time since startup, such as `3d 4h`. Used memory includes internal, wired and compressed pages, excluding purgeable pages. With `processes`, also `lists.memory` and `lists.cpu`; see [Processes](#processes). |
| `network` | `values.download` and `values.upload`: aggregate bytes/second across up `en*` Wi-Fi/Ethernet interfaces. `fields.interface`: interface names. `fields.downloadRate` and `fields.uploadRate`: formatted speeds. `lists.interfaces`: rows with `name`, byte/second `download` and `upload`, and formatted `downloadRate` and `uploadRate`. Provider `units` chooses `bytes` (default, KiB/s and MiB/s) or `bits` (kbit/s and Mbit/s); numeric values remain bytes/second. Virtual VPN interfaces are excluded to avoid counting the same traffic twice. |
| `battery` | `value` and `values.percent`: charge fraction. `fields.percent`: whole percentage; `fields.state`: `charging`, `charged` (on the adapter, not charging), `battery` or `ac`; `fields.present`: `true`/`false`; `fields.health`: `service` when macOS recommends servicing the battery, as the condition in System Settings shows, else `normal`; optional `fields.timeRemaining`: minutes. `icon` shows the charge in quarters, or a bolt while charging, and `tooltip` the percentage with the time left or until full, and “Service recommended” on a second line when it applies. Desktops without a battery return `AC` without a charge value. Updates when the charge, the time remaining or the power source changes, without polling. |
| `audio` | `value` and `values.volume`: output-volume fraction when supported. `icon`: `speaker.slash` while muted or without an output device, else `speaker` at zero and `speaker.wave.1`, `speaker.wave.2` or `speaker.wave.3` as the volume rises past each third (`speaker.wave.2` without a volume control). `fields.device`, `fields.deviceID`, `fields.volumeAvailable` and optional `fields.muted`; `lists.devices`: output-device rows with `id` and `name`. When the volume or mute state changes, as `volumeChange` reports it, `temporary` shows `fields.changedVolume` for 1.5 seconds: the volume, such as `62%`, empty while muted or without a volume control. Fixed-volume devices can omit volume, and no output device returns `No output`. Updates as soon as the volume, the mute state or the default output device changes, without polling. |
| `calendar` | The next meeting and today's agenda; see [Calendar](#calendar). |

Fractions use 0–1. CPU and network rates are deltas; their first sample after startup or resume is zero. `audio` and `battery` add a graph sample for each change rather than each interval. Native audio is a data source; the Sound widget's hover slider sets the volume itself, and in your own layouts and popups a control's `onChange` command can change volume or devices.

Native providers can't return `state`. Give their widgets `rules` to set a data state from `values` or `fields`, such as a battery `warning` at 20 %; see [Data states](styling.md#data-states).

Scripts and providers expose diagnostics in **Settings → Status** and the runtime query: running/suspended state, last event/start/update, execution duration, bounded stdout/stderr, execution/failure/restart counts and next retry delay. Streams and the native sources macOS notifies of changes, such as `battery` and `audio`, count as running while connected, and each update sets their last update time. CPU time is cumulative completed-command CPU time, not a live resource meter for a running stream. Diagnostics and graph history survive style-only edits and suspension. The existing process-group cancellation limit for deliberately detached descendants also applies to streams.

## Processes

Set `processes` on a `system` provider to list the apps and processes using the most memory in `lists.memory`, and the most CPU in `lists.cpu`, that many of each. A process whose program lies inside a running app, such as a browser's helpers, counts toward that app's row. Each row has `name`, `pid` (the app's, for an app), `path` (the app or program, which an [`image`](popups.md) block shows as its icon), `memory`, such as `1.2 GB`, and `cpu`, a whole percentage of one core, which passes 100 when a process uses several. Only your own processes are listed, the ones you can quit without an administrator's password. A [`quitField`](popups.md) block quits a row's app or process. `processes` defaults to `0`, which lists none and doesn't read them.

```json
"providers": { "system": { "type": "system", "interval": 2, "processes": 5 } }
```

The Essentials app list uses `lists.apps`, an alias of `lists.memory` or `lists.cpu` selected by `sortBy` (`memory` by default). `cpuWarning` and `memoryWarning` default to `0.9`: exceeding either fraction applies the `warning` style to a System monitor widget with `details: true`. Memory pressure `warning` or thermal state `serious` also warns; critical pressure or heat applies `critical`. These built-in warnings apply only when the widget has no custom rules. Other widgets and existing Store packages keep their own rules. Values above `1` disable the corresponding usage threshold, while pressure and heat still warn.

## Calendar

A `calendar` provider reads your calendars through EventKit. It asks for Calendars access the first time it updates, not when StableBar starts, and setup lists that access whenever an enabled widget shows a calendar provider. All-day events are skipped.

| Setting | Default | Meaning |
| --- | --- | --- |
| `calendars` | all | Calendar names to include, as shown in Calendar |
| `lookahead` | `24` | Hours ahead to look for the next meeting |
| `soon` | `15` | Whole minutes before the start when the `soon` phase begins |
| `now` | `5` | Whole minutes before the start when the `now` phase begins |

Output:

- `text`: the next meeting's title, `No meetings` or `No calendar access`.
- `fields.access`: `granted`, `denied` or `notDetermined`. Without access, it is the only field.
- `fields.phase`: `none` when no meeting starts within `lookahead`; otherwise `later`, `soon`, `now`, or `live` while the meeting runs.
- `fields.title`, `fields.start` and `fields.end`: the meeting in progress, or else the next one. Times use your short time format.
- `fields.minutes`: whole minutes until it starts, or until it ends while `live`, rounded up.
- `fields.link`: the first Google Meet (`meet.google.com`), Zoom (`zoom.us`) or Teams (`teams.microsoft.com`, `teams.live.com`) HTTPS URL in the event's URL, location or notes. A link ends at the first character other than `A–Z a–z 0–9 . _ ~ % / ? = & + # : @ -`, so it never contains a quote or other shell syntax. Use it with `openField`. `fields.joinCommand` is `open '<link>'` and exists only with a link; use it with `onClickField`.
- `values.remaining`: before the start, the share of the `soon` lead time left; while `live`, the share of the meeting left. `targets.remaining` is the value one minute later, so a progress block with a 60-second `linear` animation shrinks smoothly.
- `lists.today`: today's events in start order, with `title`, `start` and `end`, plus `link` and `joinCommand` when the event has a link.

With access, the provider updates at each minute and phase boundary and when your calendars or the Calendars permission change. Until access is granted, it checks again every `interval`. `denied` also covers restricted and add-only access; change it in **System Settings → Privacy & Security → Calendars**.

```json
{
  "providers": {
    "meetings": { "type": "calendar", "calendars": ["Work"], "soon": 10 }
  },
  "widgets": [
    {
      "id": "meeting", "type": "provider", "provider": "meetings", "position": "right",
      "layout": {
        "type": "row", "style": { "spacing": 6 },
        "children": [
          { "type": "field", "field": "text" },
          { "type": "field", "field": "minutes", "hideWhenEmpty": "minutes" },
          { "type": "text", "text": "min", "hideWhenEmpty": "minutes" }
        ]
      },
      "overlay": {
        "type": "progress", "source": "remaining", "height": 2,
        "animation": { "curve": "linear", "duration": 60 }
      },
      "popup": {
        "style": {},
        "layout": {
          "type": "column",
          "children": [
            {
              "type": "row",
              "children": [
                { "type": "field", "field": "title" },
                { "type": "symbol", "name": "video", "openField": "link", "hideWhenEmpty": "link" }
              ]
            },
            {
              "type": "list", "source": "today",
              "row": {
                "type": "row", "openField": "link",
                "children": [
                  { "type": "field", "field": "start", "style": { "width": 56 } },
                  { "type": "field", "field": "title" }
                ]
              }
            },
            {
              "type": "button", "title": "Calendar access",
              "onClick": "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars'"
            }
          ]
        }
      }
    }
  ]
}
```
