# How MountMate works

MountMate is two pieces. **`MountMateCore`** is a library holding everything that
decides what to do: mounting, retrying, recovering, storing settings and passwords.
All of it is tested without a network or a NAS. **`MountMate`** is the app: a menu bar
item and a Settings window drawn in SwiftUI over that library.

## Mounting without a dialog

Every mount goes through `NetFSMountURLSync`, macOS's own network-mount call, with its
authentication UI switched off (`kNAUIOptionNoUI`). That one option is the reason the
app exists. AppleScript's `mount volume` uses the same framework with the UI on, so a
failure puts a dialog on screen and waits for a person. Here a failure comes back as
an error the app can report and retry.

The password is passed as a separate argument to that call. It is never put in a URL,
never written to the settings file, and never appears in a process listing.

## Keeping a share mounted

The engine brings one share to a mounted state at a time and never runs two attempts
at the same share. Each attempt:

1. **Checks what is already mounted,** by reading the mount table without touching
   the network, so a dead server cannot make the check hang. A share that is mounted
   and responding is left alone.
2. **Clears a dead mount.** A share that is listed but no longer responds is
   force-unmounted, then mounted again.
3. **Checks the mount point is free.** macOS never fails on an occupied
   `/Volumes/<share>`. It quietly mounts at `/Volumes/<share>-1` instead, and anything
   configured against the usual path then finds nothing. MountMate checks first and
   refuses, saying what is in the way.
4. **Mounts,** with a 45-second deadline.
5. **Verifies where the share landed.** If it isn't the expected path anyway, the
   stray mount is removed and the failure reported.

### When it tries

| Trigger | Why |
|---|---|
| Network change | A NAS that comes back should be remounted within seconds |
| Wake from sleep | A share can be left disconnected or stale by sleep |
| Launch | |
| You, from the menu or Settings | |
| Regular sweep, every 1–60 minutes (default 5) | Catches anything the events missed, and doubles as the health check |

A failed share is retried after 5 seconds, then 10, 20 and so on, up to 5 minutes.
Only a real change resets that — the network coming back or the Mac waking — so a
flaky connection can't turn retries into a flood.

### Unmounting means "stop"

Clicking a mounted share unmounts it and switches it off. Without that, the next
sweep would simply mount it again, and the app would be fighting the person using it.
Clicking it again switches it back on and mounts it.

## When a call never returns

A network mount can block inside the system indefinitely, and a blocked system call
can't be cancelled. So every one runs on its own thread with a deadline. The deadline
frees MountMate to carry on; the stranded call is left to finish whenever it can.

Two rules keep those stranded calls from causing damage:

- **At most three per share.** Past that, new attempts are refused until the old ones
  return, instead of stranding a thread on every retry forever.
- **A stranded attempt cleans up after itself.** A call that eventually succeeds still
  mounts the share, and nobody is waiting to check where it landed. So the thread
  that made the call checks for itself, and removes the mount if it landed in the
  wrong place.

## Recovering the network-mount agent

Every network mount on a Mac is handled by a background process, `NetAuthSysAgent`.
It can get stuck partway through a mount — for example while waiting on a reply the
server never sends — and then every later mount queues behind it. Restarting it
fixes it, and launchd starts a fresh copy on demand.

MountMate does that itself when all three of these hold:

1. A mount **timed out**, or was refused because an earlier one is still stuck.
2. The server **still accepts connections** on its file-sharing port. If it doesn't,
   the problem is the network, and restarting the agent would change nothing.
3. It hasn't restarted the agent in the **last five minutes**.

It sends the agent `SIGTERM`, then `SIGKILL` two seconds later to the same process if
it hasn't exited. It never signals a fresh agent that launchd started in between.
Every restart appears in the activity log, and every decision — including declining
to act — is written to the system log:

```bash
log show --predicate 'subsystem == "com.sergio.mountmate" AND category == "recovery"'
```

## Passwords and the Keychain

Passwords are stored as generic passwords in the login Keychain under MountMate's own
service, `com.sergio.mountmate`. They deliberately don't reuse the internet passwords
Finder saves for the same server. Sharing that entry would let MountMate damage the
credential Finder depends on, so the password is entered once in Settings instead.

Whether macOS asks before MountMate reads its own password depends on how the app is
signed. Every Keychain item carries a list of which code may read it without asking.

- **Signed with a developer team** (for example, an *Apple Development* identity from
  any Apple ID signed into Xcode): the item is tied to the team, so every build of
  MountMate reads it silently, including future updates.
- **Without a team** (self-signed or unsigned): the item is tied to the exact binary
  that saved it. Each new build is a stranger, and macOS asks for your login password
  the first time it reads the item. *Always Allow* helps only until the next build.
  The download from GitHub Releases is self-signed, so it is in this group.

Diagnostics warns when the second case applies, and the copied diagnostics report
states which one does.

## Settings, logs and notifications

- **Shares** are kept in `endpoints.json`, a file you can read, edit and back up. It
  is loaded entry by entry, so one broken entry is skipped and reported rather than
  losing the rest. A file that can't be read at all is kept aside, not overwritten.
- **Preferences** such as the check interval and notifications are kept in the app's
  standard preferences.
- **The activity log** is a file next to `endpoints.json`. It records only changes, so
  a quiet log means nothing happened, not that the app wasn't running. It is trimmed
  to a fixed length.
- **Notifications** come after a share has failed twice in a row, so a blip that the
  next retry fixes stays silent. Another one follows when the share comes back.

## Only one copy runs

Two copies mounting the same shares race each other, and the loser lands at
`<share>-1`. MountMate takes an exclusive lock at launch. A second copy that can't get
it says so and quits.
