"""Launch the shipped arena UI against a finished local spar replay.

This adapter intentionally lives outside ``kit/``: RULES.md makes that tree
read-only.  It reuses the shipped request handler and adds one local NDJSON
endpoint so SparView can use ReplaySource and expose its scrubber controls.
"""
from __future__ import annotations

import argparse
import sys
import webbrowser
from http.server import HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse

from kit.arena_ui.serve import Handler, RUNS, _latest_run

UI_HTML = Path(__file__).resolve().parent / "kit" / "arena_ui" / "spar.html"


class ReplayHandler(Handler):
    """The shipped handler plus a read-only endpoint for one run's JSONL."""

    total_rounds = 10

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html", "/spar.html"):
            if not UI_HTML.is_file():
                self._json({"error": "spar.html not built - run make ui"}, 404)
                return
            html = UI_HTML.read_text(encoding="utf-8")
            html = html.replace("totalRounds: 10", f"totalRounds: {self.total_rounds}")
            body = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path != "/replay":
            super().do_GET()
            return

        query = parse_qs(parsed.query)
        run = (query.get("run") or [self.run_name or ""])[0]
        if not run or Path(run).name != run:
            self._json({"error": "invalid run"}, 400)
            return
        path = RUNS / run / "events.jsonl"
        if not path.is_file():
            self._json({"error": "run events not found"}, 404)
            return

        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", default=None, help="directory under runs/; defaults to newest")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--rounds", type=int, default=10, help="total rounds shown by the UI")
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args(argv)

    if args.rounds < 1:
        parser.error("--rounds must be at least 1")

    run = args.run or _latest_run()
    if run is None:
        print("no runs yet — run spar.py with --ui first", file=sys.stderr)
        return 2
    ReplayHandler.run_name = run
    ReplayHandler.total_rounds = args.rounds

    query = urlencode({"replay": f"/replay?run={run}"})
    url = f"http://localhost:{args.port}/?{query}"
    print(f"  arena replay: {url}\n  serving runs/{run}   (ctrl-c to stop)")
    if not args.no_open:
        webbrowser.open(url)
    try:
        HTTPServer(("127.0.0.1", args.port), ReplayHandler).serve_forever()
    except KeyboardInterrupt:
        print("\n  stopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
