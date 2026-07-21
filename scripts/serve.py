#!/usr/bin/env python3
"""Static file server for the Emscripten build with source-map support.

`python3 -m http.server` cannot add custom response headers, which makes it
awkward to serve the wasm/JS source maps emitted by an `emcc -gsource-map`
build. This drop-in replacement subclasses SimpleHTTPRequestHandler to:

  * send a `SourceMap:` header for .js/.wasm responses so browser devtools can
    locate `<file>.map` (handy when the inline `//# sourceMappingURL=` comment
    is stripped or you want to override it), and
  * send the COOP/COEP headers required for Emscripten's SharedArrayBuffer /
    pthreads builds, which the stdlib CLI server cannot set at all.

Usage:
    python3 scripts/serve.py [directory] [--port PORT] [--no-coep]

`directory` defaults to the current directory. Point it at the CMake build
directory that contains index.html, e.g.:
    python3 scripts/serve.py build --port 8000
"""
import argparse
import functools
import http.server
import socketserver

# Serve wasm with the correct MIME type on older Python versions that predate
# it in the stdlib map; harmless where it is already registered.
http.server.SimpleHTTPRequestHandler.extensions_map.setdefault(
    ".wasm", "application/wasm")


class SourceMapHandler(http.server.SimpleHTTPRequestHandler):
    coep = True

    def end_headers(self):
        path = self.path.split("?", 1)[0]
        if path.endswith((".js", ".wasm")):
            self.send_header("SourceMap", path + ".map")
        if self.coep:
            # Required for SharedArrayBuffer / Emscripten pthreads builds.
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", nargs="?", default=".",
                        help="directory to serve (default: current directory)")
    parser.add_argument("--port", type=int, default=8000,
                        help="port to listen on (default: 8000)")
    parser.add_argument("--no-coep", action="store_true",
                        help="omit the COOP/COEP headers")
    args = parser.parse_args()

    SourceMapHandler.coep = not args.no_coep
    handler = functools.partial(SourceMapHandler, directory=args.directory)

    # Allow quick restarts without waiting for the socket TIME_WAIT to clear.
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", args.port), handler) as httpd:
        print(f"serving {args.directory!r} on http://localhost:{args.port}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print()


if __name__ == "__main__":
    main()
