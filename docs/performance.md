# Performance

What StableBar costs while it runs, measured on one Mac, and how to measure your own setup.

## At idle

| | Starter configuration | Presentation example |
| --- | --- | --- |
| CPU | 0.14 % | 0.15 % |
| Wakeups | 1.3 a second | 1.1 a second |
| Wakeups from package idle | under 0.01 a second | under 0.01 a second |
| Memory | 31 MB | 45 MB |
| Energy Impact | 0.1 | 0.1 to 0.2 |

CPU is a share of one core: 0.14 % is about 5 seconds of CPU time an hour. Wakeups count the interrupts, mostly timers, that ran one of the bar's threads; wakeups from package idle are the ones that woke a fully idle processor, which cost the most energy. Memory is the physical footprint, which Activity Monitor shows as Memory. It stayed the same over 1 hour 30 minutes.

## Switching workspaces

Switching AeroSpace workspaces once a second for two minutes, the presentation example's bar used 4.3 % CPU, about 45 ms of CPU time a switch, and woke 22 times a second. The starter configuration has no Workspaces widget and stayed at its idle cost.

## What was measured

- StableBar 0.12.0, built from its tag in release configuration with `scripts/build.sh`, so without the update feed.
- A 14-inch MacBook Pro with an M3 Pro (11 cores) and 18 GB of memory, on power, running macOS 26.6.2 on its built-in display only.
- The starter configuration is the file StableBar writes when none exists and the bar takes the top edge: Apple menu, App menus, Sound, Clock and Menu bar items. When the macOS menu bar stays visible, StableBar writes the starter for below it instead, with Workspaces from the window manager it finds, or macOS Spaces without one, System and Sound; that one wasn't measured. The presentation example is [examples/presentation](../examples/presentation) with its Tonhalle Line theme: 18 widgets, including Workspaces from AeroSpace, the active app, two clocks, a script and widgets fed by one command provider every 60 seconds.
- Each bar ran from its own configuration file beside the usual bar, with the display on and the pointer away from it. The numbers start 5 minutes after launch. The build had no Accessibility access, so App menus and Menu bar items didn't read other apps' menus.
- Scripts and command providers run as their own processes, so their cost isn't in these numbers: a script costs what its command costs, as often as its interval runs it. Scripts and providers pause while the Mac sleeps.
- Not measured yet: a second display, and memory after a full day.

## Measure your own

Find the bar's process ID with `pgrep -x StableBar`, which lists every running bar.

- **CPU:** run `ps -o time= -p PID` twice, an hour apart. The difference is the CPU time the bar used in that hour; divide it by 3,600 seconds for its share of a core. Activity Monitor's **% CPU** shows the same, averaged over a few seconds.
- **Wakeups and energy:** `sudo powermetrics --samplers tasks -i 60000 -n 1` lists each process's interrupt and package idle wakeups a second over one minute. `top -pid PID -stats pid,command,cpu,idlew,power` and Activity Monitor's **Energy** tab show idle wakeups and **Energy Impact**.
- **Memory:** `footprint PID`, or Activity Monitor's **Memory**.

To compare setups, start a second bar from another file with `/Applications/StableBar.app/Contents/MacOS/StableBar --config PATH &`, using your own path to the app if it's elsewhere; `$!` is then that bar's process ID. A file that doesn't exist yet gets the starter configuration.
