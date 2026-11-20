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

Provider `type` is `command`, `stream`, `http`, `system`, `network`, `wifi`, `battery`, `bluetooth`, `audio`, `inputSource`, `microphone`, `nowPlaying`, `privacy`, `calendar`, `disk` or `merge`. `command` and `stream` require a shell `command`, `http` a `url` and an `output` (see [HTTP](#http)), and `merge` the `providers` it combines (see [Merge](#merge)). `interval` defaults to 5 seconds: the polling interval for commands, `http`, `system` and `network` (60 seconds for `http` and `disk`, and 120 for `bluetooth`), and for `calendar` until it has access; the first reconnect delay for streams; and for `wifi`, `audio`, `inputSource`, `microphone`, `privacy` and `battery`, which update when macOS reports a change, the first retry delay after a failure. That first delay is `interval`, or 1 second if `interval` is shorter. `timeout` defaults to 10 seconds and applies to command and `http` providers; streams remain running until they exit, fail, suspend or stop. Provider intervals and timeouts must be positive and finite.

A widget with `type` set to `system`, `network`, `wifi`, `battery`, `bluetooth`, `audio`, `inputSource`, `microphone`, `privacy`, `calendar` or `disk` uses the provider of that name. Without a definition in `providers`, it is a native provider of that type with default settings, shared by every widget that names it. An implicit `system` provider uses a 2-second interval and lists 5 apps when a consumer enables Essentials details. Define a provider with the same name to change its interval or other settings. `{ "id": "power", "type": "battery", "position": "right" }` is enough for a battery widget.

Provider `environment` overlays the top-level environment. `NAME` is the provider name, `CONFIG_DIR` remains the main configuration directory, and `STABLEBAR` and `STABLEBAR_CONFIG` remain the running bar's. The environment of a consuming widget applies to that widget's actions, not the shared update process. Add `events` to a provider or consuming widget to request updates; one event refreshes a shared provider once. An explicit refresh restarts a stream's process with the new event payload, and restarts the listener of a push source such as `battery`, which then reads its current state again.

A stream writes one complete JSON object per line, including `text`, and flushes stdout after each update. Empty lines are ignored; the final line may omit its newline. Streaming output represents current state: when updates arrive faster than the UI consumes them, only the newest pending update is retained. Each line is limited to 1 MiB; stderr retains its latest 16 KiB. Malformed output stops the process and retains the last good value. Clean exits and failures reconnect with exponential backoff, capped at five minutes or the configured interval if longer. Ten seconds of successful streaming resets the failure streak.

Set `whenVisible` to `true` to suspend a provider when none of its consumers is visible on any display, including widgets moved to overflow. Removing or disabling the last consuming widget stops the provider. Even when none of its consumers is visible, a provider whose events a widget subscribes to stays running; see [Script events](create-a-widget.md#script-events). Scripts and providers pause while the Mac or its displays sleep, while the screen is locked and while another user has the Mac through fast user switching, and run again once none of these holds: a Mac that wakes on the lock screen keeps them paused until you unlock it, and a script subscribed to `wake` then gets `resume` instead. Resuming preserves the last output and graph history, and starts a fresh update with `SENDER=resume`. A suspended or stopped `wifi`, `audio`, `inputSource`, `microphone`, `privacy` or `battery` provider removes its macOS listeners.

Native providers use public macOS APIs and launch no shell commands. The exceptions are `bluetooth`, which runs `system_profiler` itself, not through a shell, and `nowPlaying`, which reads the private MediaRemote framework through StableBar's own library in `/usr/bin/perl`:

| Type | Output contract |
| --- | --- |
| `system` | `value` and `values.cpu`: CPU fraction, made of `values.cpuUser` for programs and `values.cpuSystem` for macOS itself; `values.memory`: used-memory fraction; `values.memoryUsed` and `values.memoryTotal`: bytes; `values.gpu`: GPU fraction, the busiest one's on a Mac with several, left out when macOS doesn't report it. `fields.cpu`, `fields.cpuUser`, `fields.cpuSystem`, `fields.memory` and `fields.gpu` are whole percentages; `fields.memoryUsed`, `fields.memoryCompressed` and `fields.swap` are sizes such as `18.2 GB`. `fields.pressure`: macOS's memory pressure, `normal`, `warning` or `critical`; `fields.thermal`: `nominal`, `fair`, `serious` or `critical`, rising as the Mac slows itself down to cool off; `fields.load`: the 1, 5 and 15 minute load averages; `fields.uptime`: the time since startup, such as `3d 4h`. Used memory includes internal, wired and compressed pages, excluding purgeable pages. `series.cpu` and `series.memory`: the last 60 CPU and used-memory fractions, which a [`graph`](popups.md) block draws with `source`; they start over after startup or resume. `fields.strain`: which of `cpu`, `memory` or `heat` warns the most, by the [warnings](#processes) set by `cpuWarning` and `memoryWarning`, `critical` before `warning` and, on a tie, heat, then memory, then CPU; empty when none warns. `values.strain`: its level, the CPU or memory fraction, or the thermal state as `0.67` for `serious` and `1` for `critical`; `0` when none warns. `fields.strainIcon`: its SF Symbol, `cpu`, `memorychip` or `thermometer.high`, for a [`symbol`](popups.md) block with `source`; empty when none warns. A change, back to none included, applies once it holds for 3 samples in a row, so a widget following it doesn't flicker. With `processes`, also `lists.memory` and `lists.cpu`; see [Processes](#processes). |
| `network` | `values.download` and `values.upload`: aggregate bytes/second across up `en*` Wi-Fi/Ethernet interfaces. `fields.interface`: interface names. `fields.downloadRate` and `fields.uploadRate`: formatted speeds. `lists.interfaces`: rows with `name`, byte/second `download` and `upload`, and formatted `downloadRate` and `uploadRate`. Provider `units` chooses `bytes` (default, KiB/s and MiB/s) or `bits` (kbit/s and Mbit/s); numeric values remain bytes/second. Virtual VPN interfaces are excluded to avoid counting the same traffic twice. `fields.connection`: `wifi`, `ethernet`, `other` or `offline`, for the path macOS sends traffic through, and `fields.connectionIcon`: its SF Symbol, `wifi`, `cable.connector`, `network` or `wifi.slash`, for a [`symbol`](popups.md) block's `source`. Both update as soon as the connection changes, without waiting for `interval`, and need no permission. |
| `wifi` | The default Wi-Fi interface. `text` and `fields.ssid`: the network's name, empty without a network or without Location access; `icon`: `wifi`, or `wifi.slash` while Wi-Fi is off. `fields.interface`: its name, such as `en0`; `fields.power`: `on` or `off`, and `values.power`: `1` or `0`; `fields.rssi`: the signal strength in dBm, such as `-58`, left out without a network; `values.signal`: the signal as a fraction, `0` at -100 dBm and below or without a network, `1` at -50 dBm and above. `fields.access`: `granted`, `denied` or `notDetermined`, for Location access. macOS gives the network's name only to apps allowed to use Location Services, so the provider asks for that access the first time it updates, not when StableBar starts; without it, it still reports the power and the signal. `denied` also covers restricted access; change it in **System Settings → Privacy & Security → Location Services**. Updates as soon as Wi-Fi turns on or off, joins or leaves a network, or its signal changes, without polling, and sends [`wifiChange`](create-a-widget.md#script-events). |
| `battery` | `value` and `values.percent`: charge fraction. `fields.percent`: whole percentage; `fields.state`: `charging`, `charged` (on the adapter, not charging), `battery` or `ac`; `fields.present`: `true`/`false`; `fields.health`: `service` when macOS recommends servicing the battery, as the condition in System Settings shows, else `normal`; optional `fields.timeRemaining`: minutes; `fields.cycles`: the cycle count, and `fields.capacity`: the maximum capacity as a whole percentage of the design capacity, as **System Settings → Battery** shows them under Battery Health; `fields.lowPower`: `true`/`false` and `values.lowPower`: 1/0, whether Low Power Mode is on. `icon` shows the charge in quarters, or a bolt while charging, and `tooltip` the percentage with the time left or until full, and “Service recommended” on a second line when it applies. Desktops without a battery return `AC` with only `state`, `present` and Low Power Mode. Updates when the charge, the time remaining, the power source or Low Power Mode changes, without polling. |
| `bluetooth` | The connected Bluetooth devices, as `system_profiler SPBluetoothDataType` lists them. `text`: how many there are, empty when none is connected. `lists.devices`: a row for each, with `name`; `kind`: `keyboard`, `mouse`, `trackpad`, `headphones` or `other`, from the type macOS gives the device; `icon`: its SF Symbol, `keyboard`, `computermouse`, `rectangle.and.hand.point.up.left`, `airpodspro` or `dot.radiowaves.left.and.right`; `battery`: the charge macOS reports, such as `100%`, or for AirPods each bud's and then the case's, such as `76% · 77%`; `level`: the lowest of those as a whole percentage, such as `76`; and `fraction`: the same as a fraction, such as `0.76`, for a [`battery`](popups.md) block's `source`. All three are empty for a device that reports no charge. `fields.summary`: the devices that report one, with their `level`, such as `Air75 100% · AirPods Pro 76%`, empty when none does. `values.lowestBattery`: the lowest charge as a fraction, left out when none reports one, so `rules` can warn when a device runs low. Needs no permission, and polls every 120 seconds by default. |
| `audio` | `value` and `values.volume`: output-volume fraction when supported. `icon`: `speaker.slash` while muted or without an output device, else `speaker` at zero and `speaker.wave.1`, `speaker.wave.2` or `speaker.wave.3` as the volume rises past each third (`speaker.wave.2` without a volume control). `fields.device`, `fields.deviceID`, `fields.volumeAvailable`, optional `fields.volume`, the volume as a whole percentage such as `64`, and optional `fields.muted`; `lists.devices`: output-device rows with `id`, `name` and `selected`, `true` for the default output and empty for the others. When the volume or mute state changes, as `volumeChange` reports it, `temporary` shows `fields.changedVolume` for 1.5 seconds: the volume, such as `62%`, empty while muted or without a volume control. Fixed-volume devices can omit volume, and no output device returns `No output`. Updates as soon as the volume, the mute state or the default output device changes, without polling. |
| `inputSource` | `text`: the selected keyboard input source's first language in capitals, such as `FR` or `EN`, or its name when it has no language; `icon`: `keyboard`. `fields.name`: its name, such as `Swiss French`; `fields.id`: its ID, such as `com.apple.keylayout.SwissFrench`; `fields.language`: its first language, such as `fr`. `lists.sources`: the enabled input sources you can switch to, as the Input menu lists them, with `id` and `name`. Updates as soon as the selected or the enabled input sources change, without polling. |
| `microphone` | The default input device, as `audio` reads the output: `value` and `values.volume`: input-volume fraction when supported; `fields.device`, `fields.deviceID`, `fields.volumeAvailable`, optional `fields.volume`, the input volume as a whole percentage, and optional `fields.muted`; `fields.inUse`: `true` while an app records from the device, or on macOS 14.0 and 14.1, which can't tell recording from playback, while any app uses it, so playing sound through a headset that is also the input counts; `lists.devices`: input-device rows with `id`, `name` and `selected`, `true` for the default input and empty for the others. `icon`: `mic.slash` while muted or without an input device, `mic.fill` while in use, else `mic`. No input device returns `No input`. Updates as soon as the volume, the mute state, its use or the default input device changes, without polling. |
| `nowPlaying` | What plays now in any app, as Control Center's Now Playing shows it: `text` and `fields.title` are the title, with `fields.artist`, `fields.album`, `fields.line`, the title and the artist; `fields.app`, the playing app's bundle ID, `fields.source`, its name, and `fields.appIcon`, its path, which an `image` block shows as its icon; `fields.playing`, `1` while it plays and empty while paused, and `fields.control`, `pause.fill` or `play.fill` for the button that pauses or plays it; `fields.elapsed` and `fields.duration`, such as `2:20` and `5:39`, and `values.progress`, 0–1, for a track with a length; `fields.canNext`, `fields.canPrevious` and `fields.canSeek`, `1` when the app takes that command, empty when it doesn't, and absent when it doesn't say; and `fields.artwork`, a file with the cover. `icon` is `music.note` while it plays, else `pause.circle`. Without anything playing, the title is empty and a `nowPlaying` widget hides. It updates as soon as the track, the app or the playback state changes, and each second while a track with a length plays. A popup's [`nowPlayingCommand`](popups.md) blocks control it. macOS 15.4 and later let only Apple's own programs read it, so StableBar reads it through `/usr/bin/perl`. |
| `privacy` | What macOS's privacy indicators show: `fields.microphone`, `true` while an app records from the default input device, as `microphone` reads it; `fields.camera`, `true` while an app uses any camera; optional `fields.muted`, the microphone's mute state; `tooltip`: `Microphone in use`, `Camera in use`, `Microphone and camera in use` or `Microphone and camera not in use`. Its widget, **Microphone & camera**, draws a microphone and a camera, lit orange and green while in use and dimmed otherwise, with `mic.slash` while the microphone is muted; with `hideWhenIdle`, it shows only what is in use and hides while nothing is. Updates as soon as either starts or stops, the mute state changes, or a camera or input device comes or goes, without polling. |
| `calendar` | The next meeting and today's agenda; see [Calendar](#calendar). |
| `disk` | `text` and `fields.percent`: how full the startup disk is, as a whole percentage, with `icon` `internaldrive` and a `tooltip` such as `412 GB free on Macintosh HD`. `values.disk`: the used fraction; `values.used`, `values.free` and `values.total`: bytes. `fields.volume`, `fields.format`: the disk's name and format; `fields.used`, `fields.free` and `fields.total`: sizes such as `412 GB`, in decimal units. Free space is what Disk Utility and `df` show: purgeable space counts as used, so Finder's Available can be larger. `lists.volumes`: a row for each other volume Finder lists, except the startup disk's own system volumes and volumes without a capacity, with `name`, `path`, `symbol`, `percent`, `fraction`, `used`, `free`, `total`, `state`, `ejectable`, `drive` (the physical drive, empty for a network share) and `driveVolumes` (the other listed volumes on that drive, comma-separated). `diskWarning` (default `0.85`) and `diskCritical` (default `0.95`) set the used fraction above which the data state is `warning` or `critical`, here and on each row's `state`; above 1 turns one off. Polls every 60 seconds by default, and refreshes when a volume is mounted, unmounted or renamed. |

Fractions use 0–1. CPU and network rates are deltas. The first network sample after startup or resume is zero, and the first CPU sample covers the time since the Mac started. `audio` and `battery` add a graph sample for each change rather than each interval. Native audio is a data source; the Sound widget's hover slider sets the volume itself, in your own layouts and popups a slider or toggle with [`set`](popups.md) sets the output's or the input's volume or mutes it, a [`selectOutputDeviceField`](popups.md) block in an `audio` provider's `devices` list switches the output to that row's device, a [`selectInputDeviceField`](popups.md) block in a `microphone` provider's `devices` list switches the input, and a control's `onChange` command can change devices. Clicking an `inputSource` widget switches to the next enabled input source, unless it has its own `onClick`, `open`, popup or menu, and a [`selectInputSourceField`](popups.md) block in its popup's `sources` list switches to that row's source.

Apart from `disk`, native providers can't return `state`. Give their widgets `rules` to set a data state from `values` or `fields`, such as a battery `warning` at 20 %; see [Data states](styling.md#data-states).

Scripts and providers expose diagnostics in **Settings → Status** and the runtime query: running/suspended state, last event/start/update, execution duration, bounded stdout/stderr, execution/failure/restart counts and next retry delay. Streams and the native sources macOS notifies of changes, such as `battery`, `audio`, `inputSource`, `microphone` and `privacy`, count as running while connected, and each update sets their last update time. CPU time is cumulative completed-command CPU time, not a live resource meter for a running stream. Diagnostics and graph history survive style-only edits and suspension. The existing process-group cancellation limit for deliberately detached descendants also applies to streams.

## Processes

Set `processes` on a `system` provider to list the apps and processes using the most memory in `lists.memory`, and the most CPU in `lists.cpu`, that many of each. A process whose program lies inside a running app, such as a browser's helpers, counts toward that app's row. Each row has `name`, `pid` (the app's, for an app), `path` (the app or program, which an [`image`](popups.md) block shows as its icon), `memory`, such as `1.2 GB`, and `cpu`, a whole percentage of one core, which passes 100 when a process uses several. Only your own processes are listed, the ones you can quit without an administrator's password. A [`quitField`](popups.md) block quits a row's app or process. `processes` defaults to `0`, which lists none and doesn't read them.

```json
"providers": { "system": { "type": "system", "interval": 2, "processes": 5 } }
```

The Essentials app list uses `lists.apps`, an alias of `lists.memory` or `lists.cpu` selected by `sortBy` (`memory` by default). `cpuWarning` and `memoryWarning` default to `0.9`: exceeding either fraction applies the `warning` style to a System monitor widget with `details: true`. Memory pressure `warning` or thermal state `serious` also warns; critical pressure or heat applies `critical`. When the widget's `layout` shows both CPU and memory, each part warns on its own: CPU use styles only the blocks showing CPU, memory use and pressure only the blocks showing memory, and heat the whole widget. A row or column whose data is all CPU or all memory counts as that part, labels included. These built-in warnings apply only when the widget has no custom rules. Other widgets and existing Store packages keep their own rules. Values above `1` disable the corresponding usage threshold, while pressure and heat still warn.

## Calendar

A `calendar` provider reads your calendars through EventKit. It asks for Calendars access the first time it updates, not when StableBar starts, and setup lists that access whenever an enabled widget shows a calendar provider. All-day events are skipped.

| Setting | Default | Meaning |
| --- | --- | --- |
| `calendars` | all | Calendar names to include, as shown in Calendar. **Calendars** in the widget's Content lists them to choose from |
| `lookahead` | `24` | Hours ahead to look for the next meeting |
| `todayOnly` | `false` | Look for the next meeting only until local midnight, even when `lookahead` reaches further |
| `soon` | `15` | Whole minutes before the start when the `soon` phase begins |
| `now` | `5` | Whole minutes before the start when the `now` phase begins |

Output:

- `text`: the next meeting's title, `No meetings` or `No calendar access`.
- `fields.access`: `granted`, `denied` or `notDetermined`. Without access, it is the only field.
- `fields.phase`: `none` when no meeting is running and none starts within `lookahead`, or before midnight with `todayOnly`; otherwise `later`, `soon`, `now`, or `live` while the meeting runs.
- `fields.title`, `fields.start` and `fields.end`: the meeting in progress, or else the next one. Times use your short time format.
- `fields.minutes`: whole minutes until it starts, or until it ends while `live`, rounded up.
- `fields.link`: the first Google Meet (`meet.google.com`), Zoom (`zoom.us`) or Teams (`teams.microsoft.com`, `teams.live.com`) HTTPS URL in the event's URL, location or notes. A link ends at the first character other than `A–Z a–z 0–9 . _ ~ % / ? = & + # : @ -`, so it never contains a quote or other shell syntax. Use it with `openField`. `fields.joinCommand` is `open '<link>'` and exists only with a link; use it with `onClickField`.
- `fields.service`: `Google Meet`, `Zoom` or `Microsoft Teams`, the service that `link` opens.
- `fields.date`: today's date in the short form your region uses, such as `Mon 16 Nov`, for an agenda's heading.
- `values.remaining`: before the start, the share of the `soon` lead time left; while `live`, the share of the meeting left. `targets.remaining` is the value one minute later, so a progress block with a 60-second `linear` animation shrinks smoothly.
- `lists.today`: today's events in start order, with `title`, `start`, `end` and `phase`, plus `link`, `joinCommand` and `service` when the event has a link. A row's `phase` is `past` once the event has ended, and otherwise the phase `fields.phase` would give it: `later`, `soon`, `now` or `live`. The row of the meeting in `fields`, in progress or else next, has `current` set to `true`, so an agenda can fade past events and highlight that one.

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

## HTTP

An `http` provider reads JSON from a web API without running a command, and copies the parts its `output` names into the output its widgets show. Each part is a [JSON Pointer](https://www.rfc-editor.org/rfc/rfc6901) into the response: `/current/temperature_2m` is the `temperature_2m` member of `current`, `/items/0/name` the `name` of the first item, and an empty pointer the whole response. In a member's name, `~1` stands for `/` and `~0` for `~`.

```json
{
  "providers": {
    "weather": {
      "type": "http",
      "url": "https://api.open-meteo.com/v1/forecast?latitude=47.37&longitude=8.54&current=temperature_2m",
      "interval": 900,
      "output": {
        "text": "/current/temperature_2m",
        "fields": { "unit": "/current_units/temperature_2m" },
        "values": { "temperature": "/current/temperature_2m" }
      }
    }
  },
  "widgets": [
    {
      "id": "weather", "type": "provider", "provider": "weather", "position": "right",
      "layout": {
        "type": "row",
        "children": [
          { "type": "field", "field": "text" },
          { "type": "field", "field": "unit" }
        ]
      }
    }
  ]
}
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `url` | required | The `https` URL to request |
| `output` | required | `text`: a pointer; `fields`, `values` and `lists`: names and their pointers |
| `headers` | none | Headers to send, such as `{ "Accept": "application/json" }` |
| `token` | none | Sent as `Authorization: Bearer <token>`, unless it is empty |
| `interval` | `60` | Seconds between requests |
| `timeout` | `10` | Seconds to wait for the server |

Output:

- `text` and `fields`: a string as the response has it, a number as JSON writes it, such as `21.4`, or `true` or `false`. StableBar doesn't round numbers or add units; show a unit the API sends as a field of its own.
- `values`: a number, or a string that holds a finite one, as some price APIs send them.
- `lists`: each object in the array becomes a row of its members that are strings, numbers or booleans. Nested objects and arrays, and items that aren't objects, are left out.
- A pointer that finds nothing, or finds an object or an array where it needs text or a number, leaves its part out: `text` is then empty.

An answer other than HTTP status 200, or one that isn't JSON, is a failure: the widget keeps its last output, shows the error and retries with backoff, as a command does. **Settings → Status** and `--query` show the last response as the provider's output. Requests keep no cache, and keep cookies only in memory until StableBar quits; a redirect to another host drops the token. `whenVisible` and `events` work as for other providers.

In a package, each `http` provider's `url` must be on one of the package's [`hosts`](packages.md#store), and the package must write out its `url` and any `headers`: `headers`, when present, is an object of strings, and neither can be a `@token.` reference. A `@setting.` reference is filled in before the check. StableBar checks this when it reviews, installs and loads the package, and the provider follows no redirect to a host that the package doesn't list: it fails with the redirect's HTTP status instead. A package that sets the `url` of a provider, directly or in a profile, fails to load when any file or profile gives that provider a `token` other than one of the package's own secrets or `null`, such as another package's secret like `@secret.github/token` or a token typed into your configuration, or when a file other than the package's sets the provider's `headers`, such as an `Authorization` header or a `@token.` reference in your configuration. StableBar doesn't check whether those profiles can be active together. Your own configuration can still point a provider anywhere, with `@token.` references too, and its token goes along. A package can set `token` to a [`secret` setting](packages.md#local-widget-packages), such as `"token": "@setting.token"`, so the token stays in the Keychain. A `"kind": "widgets"` package, which runs no commands, can define `http` providers: [examples/packages/weather](../examples/packages/weather/config.json) shows the temperature from Open-Meteo.

## Merge

A `merge` provider combines the providers it names in `providers`, so one widget can show several of them, such as the battery, the network and the volume. Its output holds each one's `values`, `fields`, `lists` and `series` under the provider's name and a dot, such as `power.percent`, `net.downloadRate` and `sound.volume`. Each one's `text`, and its `icon` and `tooltip` when it has them, become fields under its name too, unless it has a field of that name: `power.icon` is the battery's own symbol, which shows the charge in quarters and a bolt while charging, and `power.tooltip` its percentage with the time left. The merge has no `text`, `icon` or `tooltip` of its own, so give its widget a `layout`. Each one's `temporary` fields show under its name for as long as they last, such as `sound.changedVolume` for 1.5 seconds after the volume changes, until another one's temporary output replaces them: `{ "type": "field", "field": "sound.changedVolume", "hideWhenEmpty": "sound.changedVolume" }` shows the new volume beside the speaker. Layouts, popups, `hoverLayout` and `rules` read these names as they read any other.

```json
{
  "providers": {
    "power": { "type": "battery" },
    "net": { "type": "network" },
    "sound": { "type": "audio" },
    "status": { "type": "merge", "providers": ["power", "net", "sound"] }
  },
  "widgets": [
    {
      "id": "status", "type": "provider", "provider": "status", "position": "right",
      "layout": {
        "type": "row", "style": { "spacing": 6 },
        "children": [
          { "type": "symbol", "source": "power.icon" },
          { "type": "field", "field": "power.percent" },
          { "type": "field", "field": "net.downloadRate" },
          { "type": "progress", "source": "sound.volume", "height": 4, "style": { "width": 40 } }
        ]
      },
      "rules": [{ "when": { "value": "power.percent", "below": 0.2 }, "state": "warning" }]
    }
  ]
}
```

Each name in `providers` must be defined in `providers`, even a native type such as `battery`, and can't be another merge. The providers a merge combines run while an enabled widget shows the merge, shared with the widgets that show them directly, and the merge updates as soon as one of them does. An event in the merge's or its widget's `events`, a finished click action of its widget and **Refresh** in **Settings → Status** refresh every provider it combines; an event in one provider's own `events` refreshes that one. One with `whenVisible` runs while a widget showing it or a merge of it is visible. A provider that needs access, such as `calendar`, reports `access` under its name, such as `meetings.access`, and **Settings → Status** says the merge's widget needs that access, as it would for the provider's own widget. A widgets package can define a merge of native providers.
