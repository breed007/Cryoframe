# Versions, retention, and storage

[← Back to contents](README.md)

A sealed job keeps a history. Each run is its own dated version, so you can restore a library as it was at a point in time. This page covers how versions accumulate, how to cap them, and how to watch the disk space they use.

## Versions

Every run of a sealed-DMG or sealed-zip job writes a new version into a dated folder under the destination, named by the date and time of the run. The Restore window lists each version with its date, so you pick the point in time you want.

A live mirror works differently. It keeps a single copy that each run updates in place, so there are no versions to choose from. If you want a history, use a sealed format.

## Retention

Keeping every version forever fills a disk. A new sealed job keeps **the last 7 versions**, which bounds it; you can change that when you make the job or any time after:

- Keep the last N versions (the default, N of 7).
- Keep all versions — unbounded, so watch the destination.
- Keep a daily, weekly, and monthly set (a grandfather-father-son scheme), which thins older versions while keeping long-range coverage.

Jobs made before this was the default keep whatever you chose then, including "keep all". Cryoframe will tell you if one of them is growing with nothing to stop it, and how much keeping only the recent versions would give back.

After each run, Cryoframe prunes the versions the policy no longer keeps. Only a complete version with a checksum manifest counts toward the policy. A version left half-written by a failed or cancelled run is swept away and never occupies a slot that would push out a good archive.

## When a destination is filling up

A full destination doesn't slow backups down, it stops them: the run fails on a free-space check and every run after it fails the same way, while the dashboard still shows the last success. Cryoframe warns first.

The measure is whether there's room for another run of that job, compared against what its last run actually took rather than a percentage of the volume. Ten percent of a 4 TB NAS is enormous; ten percent of a 500 GB drive is nothing. When there isn't, the main window says so and the scheduled runner sends it as an alert, at most once a day per destination.

## Storage

The Storage button at the top of the window shows, for each job, how much space its archives use and how full the destination volume is. Expand a job to see the per-version breakdown, so you can tell which versions are large and whether your retention policy is keeping more than you expected.

This is the place to look before a disk fills. If a job is using more than you want, tighten its retention policy, and the next run prunes down to the new limit.

## A worked example

Say you back up Photos as a sealed DMG every night and keep the last 14 versions. After two weeks you have 14 dated archives. On the fifteenth night, the new version is written, the oldest is pruned, and you stay at 14. The Storage view shows all 14 with their sizes, and the volume's free space, so you can see at a glance whether 14 still fits or whether to drop to 7.
