# mtg-deck-sync

Syncs public [Moxfield](https://moxfield.com) decklists into local
[Cockatrice](https://cockatrice.github.io) `.cod` files on Windows.

It wraps the [`architrice`](https://pypi.org/project/architrice/) PyPI package,
monkeypatching it **at runtime** before handing over control. Patching in
process rather than editing `site-packages` means the fixes survive a
`pip install -U architrice`.

## Setup on a new machine

```powershell
powershell -ExecutionPolicy Bypass -File bootstrap.ps1
```

That finds or installs Python, installs architrice, builds the launcher
shortcuts, and runs a first sync. Then pin the launcher by hand (see
[Taskbar pinning](#taskbar-pinning)).

## Usage

```
sync-decks.cmd            # sync (default)
sync-decks.cmd sync       # same
sync-decks.cmd latest     # only the most recently updated deck
sync-decks.cmd profiles   # list configured architrice profiles
sync-decks.cmd setup      # create the profile without syncing
sync-decks.cmd remove     # delete a profile
```

Decks land in `%LOCALAPPDATA%\Cockatrice\Cockatrice\decks`.

### Configuration

All optional — the defaults work:

| Variable | Default |
|---|---|
| `MOXFIELD_USER` | `AnimaZen` |
| `COCKATRICE_DECKS_DIR` | `%LOCALAPPDATA%\Cockatrice\Cockatrice\decks` |
| `MTG_SYNC_PYTHON` | auto-discovered |
| `COCKATRICE_EXE` | auto-discovered |
| `ARCHITRICE_MOXFIELD_URL_BASE` | `https://api2.moxfield.com/` |

Moxfield syncs **public decks only**.

## Files

| File | Role |
|---|---|
| `sync_decks.py` | The wrapper: applies all patches, then runs `architrice.main()` |
| `sync-decks.cmd` | Entry point; resolves a Python interpreter |
| `bootstrap.ps1` | Fresh-machine setup |
| `setup-launcher.ps1` | Builds the two AUMID-stamped shortcuts |
| `launch-cockatrice.vbs` | Syncs hidden, then opens Cockatrice |
| `run-sync-background.cmd` | Sync wrapper that logs to a file |

## The architrice patches

The architrice release this was built on was broken against the current
Moxfield and Scryfall APIs. All of these are applied in `sync_decks.py`.
Patches 1–3 have since been merged upstream (see [Upstream](#upstream)).

1. **Moxfield deck list (404).** `Moxfield._get_deck_list` used
   `v2/users/{user}/decks`, which was removed. Replaced with
   `v2/decks/search` + `authorUserNames`. Results still carry `publicId` and
   `lastUpdatedAtUtc`, so the existing conversion works unchanged.

2. **Rate limiting.** Moxfield allows ~1 req/sec and returns **empty bodies**
   (not always a 503) under architrice's concurrent downloads, which makes
   `.json()` raise and kills the sync. Requests are serialised behind a lock,
   spaced ~1.2s apart, and retried ~6 times on an empty or non-200 response.

3. **Scryfall User-Agent (400).** `card_info` called `requests.get` with no
   User-Agent; Scryfall now answers HTTP 400 `generic_user_agent`. The
   `requests` module in `card_info` is wrapped so every `.get()` injects a
   descriptive one.

4. **Scryfall bulk format.** *Not in the original patch set — the API moved
   again.* The bulk-data object no longer has `download_uri` at all; it is now
   `jsonl_download_uri`, serving **gzipped JSON Lines** instead of one JSON
   array. `update_card_list` is replaced to resolve either URI and stream the
   JSONL into the card DB in chunks. It downloads to a temp file first:
   reading the gzip stream straight off the socket dies with
   `ValueError: read of closed file`, because the per-chunk DB writes leave the
   connection idle long enough for urllib3 to close the raw stream. It also
   records the update timestamp **only after a successful ingest** — architrice
   stamps it before downloading, so a failed download makes it skip retrying
   for 24h and silently fall back to slow per-card lookups.

5. **Dead proxy.** *Not in the original patch set.* architrice ships
   `URL_BASE = "http://moxfield-proxy.feik.xyz/"` (the package author's nginx
   proxy). That host still resolves but refuses connections on :80 and :443,
   so every request hangs to timeout. `api2.moxfield.com` serves the same
   paths directly, with identical payloads and no auth.

6. **UTF-8 logging.** Deck names contain emoji; architrice's log `FileHandler`
   opens as cp1252 and raises `UnicodeEncodeError` (noisy, non-fatal).
   `set_up_logger` is replaced to use `encoding="utf-8"` plus
   `basicConfig(force=True)`, and `sys.stdout`/`sys.stderr` are reconfigured
   at start.

7. **Banner card = commander.** `Cockatrice.deck_to_xml` is replaced to also
   emit `<bannerCard providerId="">{commander}</bannerCard>` right after
   `<deckname>`, taking the commander from `deck.get_board("commanders")[0][1]`
   via `front_face_name()` so DFCs resolve to the front face.

### Self-heal profile logic

Every `sync` first checks `architrice -i -q -j` **as a subprocess** (not in
process — that mode reconfigures logging and would trample the real run's
setup). If it reports zero profiles, the profile is created and then the sync
proceeds.

This matters because a profile created in one environment or session may not
be present in the architrice database the real session reads
(`%LOCALAPPDATA%\architrice\architrice.db`). A sandboxed or scheduled process
may run with a redirected `LOCALAPPDATA`; the self-heal covers that without
env-var overrides.

## Taskbar pinning

Pin through the normal Windows UI. Editing the taskband registry
(`Favorites` / `FavoritesResolve`) or pinned `.lnk` files directly can leave a
ghost icon that can't be unpinned.

On Windows 11 (26xxx builds) **Pin to taskbar is absent from File Explorer's
context menu** for shortcuts. Pin from the Start menu instead, which is why
`setup-launcher.ps1`'s output is copied into
`%APPDATA%\Microsoft\Windows\Start Menu\Programs`:

> Start → All apps → **Cockatrice (Deck Sync)** → right-click → Pin to taskbar

Then unpin the pre-existing Cockatrice icon.

### The AUMID trick

Two shortcuts, both stamped with the same `AppUserModelID`
(`Architrice.Cockatrice`):

- `cockatrice_aumid.lnk` → `cockatrice.exe` (helper, launched by the VBS)
- `Cockatrice.lnk` → `wscript.exe launch-cockatrice.vbs` (the one you pin)

Matching IDs are what should make the running Cockatrice window group under
the single pinned button instead of showing a second icon. Setting an AUMID on
a `.lnk` is not exposed by `WScript.Shell` — it needs the shell's
`IPropertyStore` (`PKEY_AppUserModel_ID`: fmtid
`{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}`, pid `5`, `VT_LPWSTR`), driven from
inline C# over `IShellLinkW` / `IPersistFile` / `IPropertyStore`.

**Status: unverified.** A shortcut's AUMID is applied to the *process*, not the
window, and there is no public API to read it back, so
`SHGetPropertyStoreForWindow` on the Cockatrice window returns empty either
way. If pinning yields two icons, the robust fix is to replace the VBS with a
small compiled launcher that calls `SetCurrentProcessExplicitAppUserModelID`
and then spawns Cockatrice as a child, which inherits the ID deterministically
instead of relying on shell propagation.

## Troubleshooting

**`sqlite3.OperationalError: disk I/O error`** — almost certainly a corrupt
index in the card database, not an actual disk problem (check free space to
rule that out). A crashed ingest can leave
`wrong # of entries in index idx_cards_name`. Repair in place:

```python
import sqlite3, os
db = sqlite3.connect(os.path.expandvars(r'%LOCALAPPDATA%\architrice\architrice.db'))
print(db.execute('pragma integrity_check').fetchone()[0])
db.execute('REINDEX'); db.execute('VACUUM'); db.commit()
print(db.execute('pragma integrity_check').fetchone()[0])
```

Back the `.db` up first. Worst case, delete it — architrice rebuilds it, at the
cost of re-downloading the card list. The profile lives in that same database,
but the self-heal recreates it.

**Nothing synced when Cockatrice opened** — check
`%LOCALAPPDATA%\architrice\sync-launch.log` for an entry matching the launch
time. No entry means the launch didn't go through the VBS, i.e. you clicked a
plain Cockatrice shortcut rather than the pinned launcher.

**Requests hang for 30s each** — the Moxfield proxy is being used. See patch 5.

## Upstream

- Patches 1–3 were merged upstream in
  [OwenFeik/architrice#11](https://github.com/OwenFeik/architrice/pull/11)
  (September 2026), fixing [issue #10](https://github.com/OwenFeik/architrice/issues/10).
  The source branch is [`DanFLewis/architrice`](https://github.com/DanFLewis/architrice) (`develop`).
- Patches 4–7 are not upstream yet.

## License

[GPL-3.0](LICENSE), the same license as architrice. `sync_decks.py` replaces
several architrice functions with modified copies of upstream code, so it's
distributed under architrice's terms.
