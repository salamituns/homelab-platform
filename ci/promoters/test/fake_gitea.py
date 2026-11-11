import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

W = sys.argv[1]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._send(200, json.load(open(f"{W}/prs.json")))

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n))
        mode = int(open(f"{W}/mode").read().strip())
        # One line per POST: "<mode> <payload-json>" so tests can check head/title/body.
        with open(f"{W}/posts", "a") as f:
            f.write(f"{mode} {json.dumps(req)}\n")
        if mode == 201:
            prs = json.load(open(f"{W}/prs.json"))
            prs.append({"number": len(prs) + 1, "head": {"ref": req["head"]}})
            json.dump(prs, open(f"{W}/prs.json", "w"))
            self._send(201, {"number": len(prs)})
        else:
            self._send(mode, {"message": "boom"})


s = HTTPServer(("127.0.0.1", 0), H)
open(f"{W}/port", "w").write(str(s.server_port))
s.serve_forever()
