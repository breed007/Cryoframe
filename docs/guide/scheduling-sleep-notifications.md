# Scheduling, sleep, and notifications

[← Back to contents](README.md)

This page covers running jobs unattended: how the schedule works, how Cryoframe keeps the Mac awake long enough to finish, and how it tells you what happened.

## Scheduling

Turn on the schedule from the top of the main window, or in Settings ▸ Schedule. It installs a launchd agent that wakes about once an hour and runs any job that is due.

Each job sets its own frequency when you make or edit it. A job set to Manual has no schedule and only runs from Run now. Scheduled jobs run while you are logged in.

The "If app is open" setting on a job decides what happens when the library's owning app is running at the scheduled time. You can proceed anyway, warn, or defer the run until the app is closed. For most libraries you can proceed, because the snapshot captures a consistent copy whether or not the app is open.

## Keeping the Mac awake

A backup that runs at 2 a.m. is no use if the Mac idle-sleeps at 2:01 and severs the copy. "Keep the Mac awake while a backup runs" is in Settings ▸ General and is on by default. It holds a power assertion for the length of a run, so the Mac does not idle-sleep partway through.

It prevents idle sleep only. It never forces the display on, and it is released while a job is paused. Closing a laptop lid still sleeps the Mac, assertion or not, because the lid switch is not something an app can override.

## Waking for a scheduled run

"Wake the Mac for scheduled backups" is in Settings ▸ General and is off by default. When on, Cryoframe asks the helper to set a system wake a couple of minutes before the next due job, so an idle Mac wakes up and runs its nightly backup near the intended time.

This changes the system power schedule, which is why it is off by default and asks the helper for permission. It only ever manages its own wake event. It cannot wake a Mac that is shut down, and it cannot beat a closed lid.

## The menu bar

Cryoframe keeps a status item in the menu bar. It shows each job's last run at a glance and turns red if anything failed. The app stays resident there even with its window closed, which is what lets it run scheduled jobs and notify you about them. Quit it from the menu bar's Quit item.

The menu-bar item also holds Verify all archives, Check for Updates, and Open Cryoframe.

## Notifications

Choose when to be notified in Settings ▸ General ▸ Notifications: never, on failure, or on every run. On failure is the default. A failed health check notifies you as well, so a corrupted archive does not go unnoticed.

## Remote alerts

A Notification Center banner is no help when you are away from the Mac. Remote alerts push a message to your phone or a chat channel when a backup fails, finishes as a partial backup, or an archive health check fails. Set them up in Settings ▸ General ▸ Remote alerts.

Two kinds:

- ntfy is the simplest. Install the ntfy app on your phone, pick a topic name, and enter `https://ntfy.sh/your-topic`. Anything sent to that topic arrives as a push.
- Webhook posts a message to a URL. The payload includes both `text` and `content` fields, so a Slack or Discord incoming webhook works as-is, and a custom endpoint gets the structured fields too.

Pick whether to alert on failures only or on every run, then use Send test alert to confirm it reaches you. Remote alerts fire independently of the notification setting above, so you can keep local banners off and still get the off-machine page. As with notifications, the menu-bar app has to be running to send them.
