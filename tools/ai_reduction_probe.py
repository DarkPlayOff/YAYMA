"""A/B probe for the "Меньше ИИ" setting.

Creates wave sessions twice (same seed): once without the
`X-Yandex-Music-AI-Content-Rate` header (standard) and once with it
(reduced), then prints the recommended tracks so you can compare.

Token is read from yayma's local DB, so run it on the machine where the app
is logged in. No VPN: the endpoint is reachable directly.

    python tools/ai_reduction_probe.py
    python tools/ai_reduction_probe.py --seed "personal:hits" --rounds 3 --pages 4
    python tools/ai_reduction_probe.py --save   # also dump raw JSON
"""

import argparse
import json
import sqlite3
import sys
import urllib.error
import urllib.request
from pathlib import Path

DB = Path.home() / "AppData/Roaming/darkplayoff.yayma.app/yayma/yamusic_v2.db"
BASE = "https://api.music.yandex.ru"
HEADER = "X-Yandex-Music-AI-Content-Rate"


def token():
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    raw = con.execute("SELECT value FROM app_settings WHERE key='auth_token'").fetchone()[0]
    con.close()
    return json.loads(raw)[0]


TOKEN = token()
AUTH_HEADERS = {
    "Authorization": "OAuth " + TOKEN,
    "X-Yandex-Music-Client": "YandexMusicDesktopAppWindows/5.110.1",
    "Accept-Language": "ru",
    "Content-Type": "application/json",
}


def post(path, body, reduced):
    headers = dict(AUTH_HEADERS)
    if reduced:
        headers[HEADER] = "reduced"
    req = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(), headers=headers, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} on {path}: {e.read().decode()[:300]}")
    if "error" in data:
        sys.exit(f"API error on {path}: {data['error']}")
    if "result" not in data:
        sys.exit(f"No result on {path}: {str(data)[:300]}")
    return data["result"]


def new_session(seed, reduced):
    return post(
        "/rotor/session/new",
        {
            "seeds": [seed],
            "queue": [],
            "includeTracksInResponse": True,
            "includeWaveModel": True,
            "interactive": True,
        },
        reduced,
    )


def next_tracks(session, queue, reduced):
    return post(
        f"/rotor/session/{session['radioSessionId']}/tracks",
        {"queue": queue, "feedbacks": []},
        reduced,
    )


def track_key(track):
    album = (track.get("albums") or [{}])[0].get("id")
    return f"{track['id']}:{album}" if album else None


def collect(seed, reduced, pages, queue=None):
    session = new_session(seed, reduced)
    tracks = []
    queue = list(queue or [])
    empty = 0
    for page in range(pages + 1):
        batch = session if page == 0 else next_tracks(session, queue, reduced)
        sequence = batch.get("sequence") or []
        if not sequence:
            empty += 1
            if empty >= 2:
                break
            continue
        empty = 0
        for item in sequence:
            track = item.get("track") or {}
            if track:
                tracks.append(track)
                key = track_key(track)
                if key:
                    queue.append(key)
    return session, tracks


def describe(track):
    artists = ", ".join(a.get("name", "?") for a in track.get("artists") or [])
    return f"{artists} — {track.get('title', '?')}  [{track.get('id')}]"


def run(seed, reduced, pages, save, queue):
    label = "reduced" if reduced else "standard"
    session, tracks = collect(seed, reduced, pages, queue)
    print(f"\n=== {label}: {len(tracks)} tracks, wave={session.get('wave', {}).get('name')!r}")
    for track in tracks:
        print("  " + describe(track))
    if not tracks:
        print("  (!) no tracks: the API answered with an empty wave. Usually means the")
        print("      request was geo-blocked (451 elsewhere) or the session needs a")
        print("      history queue, see --queue in --help.")
    if save:
        out = Path(f"ai_reduction_{label}.json")
        out.write_text(json.dumps({"session": session, "tracks": tracks}, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"  raw json -> {out}")
    return tracks


def account_flag():
    """Server-side value of the setting (official clients store it there)."""
    req = urllib.request.Request(
        BASE + "/account/settings", headers=AUTH_HEADERS, method="GET"
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())["result"].get("aiContentReductionEnabled")


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--seed",
        default="user:onyourwave,personal:hits",
        help="comma-separated rotor seeds (default: user:onyourwave,personal:hits)",
    )
    parser.add_argument("--rounds", type=int, default=2, help="sessions per mode (2+ gives the baseline)")
    parser.add_argument("--pages", type=int, default=3, help="track pages per session (~5 tracks each)")
    parser.add_argument(
        "--queue",
        default="",
        help="comma-separated history seeds (trackId:albumId) to start from, e.g. 123:456,789:012",
    )
    parser.add_argument("--save", action="store_true", help="write raw JSON next to the script")
    args = parser.parse_args()
    queue = [item for item in args.queue.split(",") if item.strip()]
    seeds = [item.strip() for item in args.seed.split(",") if item.strip()]

    print(f"account/settings aiContentReductionEnabled = {account_flag()}")
    for seed in seeds:
        compare(seed, args, queue)


def compare(seed, args, queue):
    print(f"\n############ seed: {seed}")
    std_rounds, red_rounds = [], []
    for _ in range(args.rounds):
        std_rounds.append({t["id"] for t in run(seed, False, args.pages, args.save, queue)})
        red_rounds.append({t["id"] for t in run(seed, True, args.pages, args.save, queue)})
    standard = set().union(*std_rounds)
    reduced = set().union(*red_rounds)

    def mean_overlap(rounds):
        pairs = [len(a & b) for i, a in enumerate(rounds) for b in rounds[i + 1 :]]
        return sum(pairs) / len(pairs) if pairs else None

    print(f"\n=== summary ({seed})")
    print(f"  standard: {len(standard)} unique tracks over {len(std_rounds)} sessions")
    print(f"  reduced : {len(reduced)} unique tracks over {len(red_rounds)} sessions")
    print(f"  overlap standard<->reduced: {len(standard & reduced)}")
    if args.rounds > 1:
        base = mean_overlap(std_rounds)
        print(f"  baseline standard<->standard: {base:.1f} tracks/session")
        print("  (if standard<->reduced is well below the baseline, the header does something)")
    else:
        print("  run with --rounds 2 (or more) to get the standard<->standard baseline")
    print("\n  No AI marker exists in the API payload, so compare the lists/artists by eye.")


if __name__ == "__main__":
    main()
