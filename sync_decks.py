#!/usr/bin/env python3
"""Sync public Moxfield decklists into local Cockatrice .cod files.

This is a thin wrapper around the `architrice` PyPI package. The published
package is broken against today's Moxfield and Scryfall APIs, so before
handing control to architrice we monkeypatch it *in process*. Patching at
runtime (rather than editing site-packages) means the fixes survive a
`pip install -U architrice`.

Usage:
    sync-decks.cmd [setup|sync|latest|profiles|remove]

`sync` is the default.
"""

import gzip
import io
import itertools
import json
import logging
import os
import subprocess
import sys
import threading
import time

# --------------------------------------------------------------------------
# Machine-specific configuration
# --------------------------------------------------------------------------

# Override either of these with MOXFIELD_USER / COCKATRICE_DECKS_DIR to reuse
# this tool for another account or a portable Cockatrice install.
MOXFIELD_USER = os.environ.get("MOXFIELD_USER", "AnimaZen")
DECKS_DIR = os.environ.get("COCKATRICE_DECKS_DIR") or os.path.join(
    os.environ["LOCALAPPDATA"], "Cockatrice", "Cockatrice", "decks"
)
PROFILE_NAME = f"moxfield-{MOXFIELD_USER}"

# Scryfall rejects the default python-requests User-Agent with HTTP 400
# (error code `generic_user_agent`), so we send a descriptive one.
SCRYFALL_USER_AGENT = (
    "architrice-deck-sync/1.0 "
    "(+https://github.com/DanFLewis/architrice) python-requests"
)

# architrice ships URL_BASE = "http://moxfield-proxy.feik.xyz/", the package
# author's nginx proxy. That host now resolves but refuses connections on
# both :80 and :443, so every request hangs until it times out. The Moxfield
# API answers the same paths directly with identical payloads, so we go
# straight there. Override with ARCHITRICE_MOXFIELD_URL_BASE if the proxy
# ever comes back.
MOXFIELD_URL_BASE = os.environ.get(
    "ARCHITRICE_MOXFIELD_URL_BASE", "https://api2.moxfield.com/"
)

# Number of cards fed to save_card_info at a time when ingesting Scryfall's
# bulk file. The uncompressed card list is now several hundred MB, so it is
# streamed rather than held in memory as one list.
SCRYFALL_INGEST_CHUNK = 20000

# Moxfield allows roughly one request per second.
MOXFIELD_MIN_INTERVAL = 1.2
MOXFIELD_MAX_TRIES = 6


# --------------------------------------------------------------------------
# Console encoding
# --------------------------------------------------------------------------


def fix_console_encoding():
    """Deck names contain emoji; the default cp1252 console blows up on them."""
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        if stream is None:
            continue
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            buffer = getattr(stream, "buffer", None)
            if buffer is not None:
                setattr(
                    sys,
                    stream_name,
                    io.TextIOWrapper(
                        buffer,
                        encoding="utf-8",
                        errors="replace",
                        line_buffering=True,
                    ),
                )


# --------------------------------------------------------------------------
# Patch 1 + 2: Moxfield source (deck list endpoint, rate limiting)
# --------------------------------------------------------------------------

_moxfield_lock = threading.Lock()
_moxfield_last_request = [0.0]


def patch_moxfield():
    import requests

    from architrice import utils
    from architrice.sources.moxfield import Moxfield

    def _request(self, url, *, params=None):
        """Serialised, rate-limited, retrying GET.

        architrice downloads decks concurrently. Moxfield responds to that by
        returning an EMPTY body (not always a 503), which makes `.json()`
        raise and takes the whole sync down. So: one request at a time, at
        least MOXFIELD_MIN_INTERVAL apart, and retry anything that isn't a
        200 with a non-empty body.
        """
        response = None
        last_error = None

        for attempt in range(MOXFIELD_MAX_TRIES):
            with _moxfield_lock:
                wait = MOXFIELD_MIN_INTERVAL - (
                    time.monotonic() - _moxfield_last_request[0]
                )
                if wait > 0:
                    time.sleep(wait)
                try:
                    response = requests.get(
                        url,
                        params=params,
                        headers={"User-Agent": utils.user_agent()},
                        timeout=30,
                    )
                    last_error = None
                except requests.RequestException as error:
                    response, last_error = None, error
                finally:
                    _moxfield_last_request[0] = time.monotonic()

            if (
                response is not None
                and response.status_code == Moxfield.REQUEST_OK
                and response.content
                and response.content.strip()
            ):
                return response

            if attempt == MOXFIELD_MAX_TRIES - 1:
                break

            if last_error is not None:
                reason = f"{type(last_error).__name__}: {last_error}"
            elif response.status_code == Moxfield.REQUEST_OK:
                reason = f"empty body (HTTP {response.status_code})"
            else:
                reason = f"HTTP {response.status_code}"

            backoff = MOXFIELD_MIN_INTERVAL * (attempt + 1) * 2
            logging.debug(
                f"Moxfield request to {url} failed ({reason}). Retrying in "
                f"{backoff:.1f}s ({attempt + 1}/{MOXFIELD_MAX_TRIES})."
            )
            time.sleep(backoff)

        if response is None:
            raise last_error
        return response

    def _get_deck_list(self, username, allpages=True):
        """v2/users/{user}/decks was removed and now 404s.

        The current equivalent is the deck search endpoint filtered by author.
        Result items still carry `publicId` and `lastUpdatedAtUtc`, so the
        existing deck_list_to_generic_format works unchanged.
        """
        decks = []
        page = 1
        while True:
            body = self._request(
                f"{Moxfield.URL_BASE}v2/decks/search",
                params={
                    "pageSize": Moxfield.DECK_LIST_PAGE_SIZE,
                    "pageNumber": page,
                    "authorUserNames": username,
                    "sortType": "updated",
                    "sortDirection": "descending",
                },
            ).json()
            decks.extend(body["data"])
            page += 1
            if page > body["totalPages"] or not allpages:
                break

        return self.deck_list_to_generic_format(decks)

    Moxfield.URL_BASE = MOXFIELD_URL_BASE
    Moxfield._request = _request
    Moxfield._get_deck_list = _get_deck_list


# --------------------------------------------------------------------------
# Patch 3: Scryfall User-Agent
# --------------------------------------------------------------------------


class _RequestsWithUserAgent:
    """Proxy around the `requests` module that injects a User-Agent on GET.

    card_info calls bare `requests.get(...)` with no headers. Scryfall now
    answers that with HTTP 400 `generic_user_agent`, so the returned JSON has
    no `download_uri` key and architrice dies with a KeyError.
    """

    def __init__(self, wrapped):
        self._wrapped = wrapped

    def __getattr__(self, name):
        return getattr(self._wrapped, name)

    def get(self, *args, **kwargs):
        headers = dict(kwargs.pop("headers", None) or {})
        headers.setdefault("User-Agent", SCRYFALL_USER_AGENT)
        headers.setdefault("Accept", "*/*")
        kwargs["headers"] = headers
        kwargs.setdefault("timeout", 120)
        return self._wrapped.get(*args, **kwargs)


def patch_scryfall_user_agent():
    from architrice.targets import card_info

    if not isinstance(card_info.requests, _RequestsWithUserAgent):
        card_info.requests = _RequestsWithUserAgent(card_info.requests)


# --------------------------------------------------------------------------
# Patch 3b: Scryfall bulk card list is now gzipped JSONL
# --------------------------------------------------------------------------


def ingest_card_lines(card_info, lines):
    """Feed Scryfall's bulk card file into architrice's card database.

    Handles the current JSON Lines format and the legacy single JSON array,
    saving in chunks so the full card list is never held in memory at once.
    Returns the number of cards ingested.
    """
    head = lines.read(1)
    while head and head.isspace():
        head = lines.read(1)

    if head == "[":
        cards = json.loads("[" + lines.read())
        card_info.save_card_info(cards)
        return len(cards)

    pending = (head + lines.readline()) if head else ""
    stream = itertools.chain([pending], lines) if pending else lines

    total = 0
    batch = []
    for line in stream:
        line = line.strip().rstrip(",")
        if not line or line in ("[", "]"):
            continue
        batch.append(json.loads(line))
        if len(batch) >= SCRYFALL_INGEST_CHUNK:
            card_info.save_card_info(batch)
            total += len(batch)
            batch = []
            logging.debug(f"Ingested {total} cards so far.")

    if batch:
        card_info.save_card_info(batch)
        total += len(batch)

    return total


def patch_scryfall_bulk_data():
    """Scryfall's bulk-data object no longer has a `download_uri`.

    It now exposes `jsonl_download_uri`, pointing at a gzipped JSON Lines
    file rather than one big JSON array. architrice's update_card_list does
    `download_info["download_uri"]` and `.json()` on the result, so it raises
    KeyError even once the User-Agent is accepted. This replacement resolves
    whichever URI is on offer and streams the JSONL into the card database in
    chunks instead of materialising the whole list.
    """
    from architrice import database, utils
    from architrice.targets import card_info

    event_id = database.DatabaseEvents.CARD_LIST_UPDATE.value

    def update_card_list():
        last_time, last_url = database.select_one(
            "database_events", ["time", "data"], id=event_id
        ) or (0, None)

        if utils.time_now() - last_time < card_info.CARD_LIST_UPDATE_INTERVAL:
            return False

        info = card_info.requests.get(card_info.SCRYFALL_BULK_DATA_URL).json()
        download_uri = info.get("download_uri") or info.get(
            "jsonl_download_uri"
        )
        if not download_uri:
            logging.error(
                "Scryfall bulk-data response contained no download URI "
                f"(keys: {sorted(info)}). Skipping card list update."
            )
            return False

        def record_update():
            database.upsert(
                "database_events",
                id=event_id,
                time=utils.time_now(),
                data=download_uri,
            )

        if download_uri == last_url:
            logging.info("Latest Scryfall card list already downloaded.")
            record_update()
            return False

        logging.info(
            "Downloading Scryfall card list for card data "
            f"({info.get('compressed_size')} bytes compressed). "
            "This may take a couple of minutes."
        )

        # Download to disk before parsing. Reading the gzip stream straight
        # off the socket is fragile: urllib3 can close the underlying raw
        # stream between chunks (ValueError: read of closed file), and the
        # per-chunk database writes leave the connection idle long enough for
        # that to happen.
        utils.ensure_data_dir()
        archive = os.path.join(utils.DATA_DIR, "scryfall-bulk.tmp")
        try:
            response = card_info.requests.get(download_uri, stream=True)
            response.raise_for_status()
            with open(archive, "wb") as handle:
                for chunk in response.iter_content(chunk_size=1 << 20):
                    if chunk:
                        handle.write(chunk)
            response.close()

            with open(archive, "rb") as probe:
                gzipped = probe.read(2) == b"\x1f\x8b"

            opener = gzip.open if gzipped else open
            with opener(archive, "rt", encoding="utf-8") as cards:
                total = ingest_card_lines(card_info, cards)
        finally:
            try:
                os.remove(archive)
            except OSError:
                pass

        # Only now, after a successful ingest. architrice stamps this before
        # downloading, so a failed download makes it skip retrying for a full
        # CARD_LIST_UPDATE_INTERVAL and fall back to slow per-card lookups.
        record_update()

        logging.info(f"Card database update complete ({total} cards).")
        return True

    card_info.update_card_list = update_card_list


# --------------------------------------------------------------------------
# Patch 4: UTF-8 logging
# --------------------------------------------------------------------------


def patch_logging():
    """architrice's FileHandler opens the log as cp1252, so emoji in deck
    names raise UnicodeEncodeError. Noisy but non-fatal; force UTF-8."""
    from architrice import utils

    def set_up_logger(verbosity=1):
        utils.ensure_data_dir()
        handlers = [logging.FileHandler(utils.LOG_FILE, encoding="utf-8")]

        if verbosity != 0:
            stdout_handler = logging.StreamHandler(sys.stdout)
            stdout_handler.setFormatter(
                logging.Formatter("%(levelname)s: %(message)s")
            )
            stdout_handler.setLevel(
                logging.INFO if verbosity == 1 else logging.DEBUG
            )
            handlers.append(stdout_handler)

        logging.basicConfig(level=logging.DEBUG, handlers=handlers, force=True)

    utils.set_up_logger = set_up_logger


# --------------------------------------------------------------------------
# Patch 5: Cockatrice banner card = commander
# --------------------------------------------------------------------------


def patch_cockatrice_banner_card():
    """Emit <bannerCard> so Cockatrice shows the commander as the deck art."""
    import xml.etree.cElementTree as et

    from architrice.targets.cockatrice import Cockatrice

    def deck_to_xml(self, deck, outfile, include_maybe, card_info_map=None):
        root = et.Element("cockatrice_deck", version="1")

        et.SubElement(root, "deckname").text = deck.name

        commanders = deck.get_board("commanders")
        if commanders:
            et.SubElement(
                root, "bannerCard", providerId=""
            ).text = self.front_face_name(commanders[0][1], card_info_map)

        et.SubElement(root, "comments").text = deck.description

        main = et.SubElement(root, "zone", name="main")
        side = et.SubElement(root, "zone", name="side")

        for quantity, name in deck.get_main_deck():
            et.SubElement(
                main,
                "card",
                number=str(quantity),
                name=self.front_face_name(name, card_info_map),
            )
        for quantity, name in deck.get_sideboard(include_maybe=include_maybe):
            et.SubElement(
                side,
                "card",
                number=str(quantity),
                name=self.front_face_name(name, card_info_map),
            )

        et.ElementTree(root).write(
            outfile, xml_declaration=True, encoding="UTF-8"
        )

    Cockatrice.deck_to_xml = deck_to_xml


def apply_patches():
    patch_logging()
    patch_moxfield()
    patch_scryfall_user_agent()
    patch_scryfall_bulk_data()
    patch_cockatrice_banner_card()


# --------------------------------------------------------------------------
# Running architrice
# --------------------------------------------------------------------------


def run_architrice(*argv):
    """Invoke architrice in-process (so the patches apply) with given args."""
    import architrice

    saved_argv = sys.argv
    sys.argv = ["architrice", *argv]
    try:
        architrice.main()
    finally:
        sys.argv = saved_argv


def list_profiles():
    """Read the profile list via a SUBPROCESS.

    Deliberately not in-process: architrice's export-json mode reconfigures
    logging and prints to stdout, which would trample the logging setup of
    the real run that follows.
    """
    result = subprocess.run(
        [sys.executable, "-m", "architrice", "-i", "-q", "-j"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        return []
    try:
        profiles = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []
    return profiles if isinstance(profiles, list) else []


def ensure_profile():
    """Self-heal: make sure a profile exists before syncing.

    A profile created in a different environment or session may not be
    present in the architrice database this run actually reads
    (%LOCALAPPDATA%\\architrice\\architrice.db), so check every time.
    """
    if list_profiles():
        return False

    print(f"No architrice profile found. Creating '{PROFILE_NAME}'...")
    os.makedirs(DECKS_DIR, exist_ok=True)
    run_architrice(
        "-i",
        "-a",
        "-s", "moxfield",
        "-u", MOXFIELD_USER,
        "-t", "cockatrice",
        "-p", DECKS_DIR,
        "-n", PROFILE_NAME,
    )
    return True


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def cmd_setup(extra):
    ensure_profile()
    print(f"Profile ready. Decks will be written to {DECKS_DIR}")


def cmd_sync(extra):
    ensure_profile()
    print(f"Syncing Moxfield decks for '{MOXFIELD_USER}' -> {DECKS_DIR}")
    run_architrice(*extra)


def cmd_latest(extra):
    ensure_profile()
    run_architrice("-l", *extra)


def cmd_profiles(extra):
    profiles = list_profiles()
    if not profiles:
        print("No profiles configured.")
        return
    print(json.dumps(profiles, indent=4))


def cmd_remove(extra):
    run_architrice("-d", *extra)


COMMANDS = {
    "setup": cmd_setup,
    "sync": cmd_sync,
    "latest": cmd_latest,
    "profiles": cmd_profiles,
    "remove": cmd_remove,
}


def main():
    fix_console_encoding()
    apply_patches()

    argv = sys.argv[1:]
    if argv and argv[0] in COMMANDS:
        command, extra = argv[0], argv[1:]
    else:
        command, extra = "sync", argv

    COMMANDS[command](extra)


if __name__ == "__main__":
    main()
