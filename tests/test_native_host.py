"""Tests for bin/native-host (native messaging protocol + validation).

A fake omarchy-shell on PATH records its arguments, so nothing real runs.
Run: python3 -I tests/test_native_host.py
"""
import json
import os
import stat
import struct
import subprocess
import tempfile
import unittest

HOST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "native-host")
GOOD = "https://open.spotify.com/intl-de/album/4LH4d3cOWNNsVw41Gqt2kv?si=abc"


class NativeHost(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.tmp.name, "args.json")
        self.reply = "started"
        fake = os.path.join(self.tmp.name, "omarchy-shell")
        with open(fake, "w") as f:
            f.write("#!/usr/bin/env python3\nimport json,sys,os\n"
                    f"json.dump(sys.argv[1:], open({self.log!r}, 'w'))\n"
                    "print(os.environ.get('FAKE_REPLY', 'started'))\n")
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, payload, raw=None, reply="started"):
        data = raw if raw is not None else json.dumps(payload).encode()
        frame = struct.pack("<I", len(data)) + data if raw is None or len(raw) < 1 << 20 else raw
        env = {"PATH": self.tmp.name + ":/usr/bin", "HOME": os.environ.get("HOME", "/tmp"), "FAKE_REPLY": reply}
        out = subprocess.run([HOST, "chrome-extension://x/"], input=frame, capture_output=True, env=env, timeout=10).stdout
        (n,) = struct.unpack("<I", out[:4])
        return json.loads(out[4:4 + n])

    def args(self):
        return json.load(open(self.log)) if os.path.exists(self.log) else None

    def test_valid_link_is_forwarded_as_single_argument(self):
        self.assertEqual(self.call({"url": GOOD})["status"], "started")
        self.assertEqual(self.args(), ["specialkapa.spotify-dl", "download", GOOD])

    def test_youtube_links_forwarded(self):
        for url in ["https://youtu.be/dQw4w9WgXcQ", "https://music.youtube.com/browse/MPREb_7ltM34kr0mH",
                    "https://www.youtube.com/playlist?list=PLSdoVPM5WnndSQEXRz704yQkKwx76GvPV"]:
            self.assertEqual(self.call({"url": url})["status"], "started", url)
            self.assertEqual(self.args()[-1], url)

    def test_busy(self):
        self.assertEqual(self.call({"url": GOOD}, reply="busy")["status"], "busy")

    def test_invalid_links_never_reach_the_shell(self):
        for url in ["https://evil.example/track/4uLU6hMCjMI75M1A2tKUQC",
                    "https://open.spotify.com/artist/0gxyHStUsqpMadRV0Di1Qt",
                    "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC $(touch /tmp/x)",
                    "--help", 42, None,
                    "https://www.youtube.com/playlist?list=RDdQw4w9WgXcQ",
                    "http://youtu.be/dQw4w9WgXcQ"]:
            self.assertEqual(self.call({"url": url})["status"], "invalid", url)
        self.assertIsNone(self.args())

    def test_oversized_message_rejected(self):
        frame = struct.pack("<I", 10 * 1024 * 1024)
        reply = self.call(None, raw=frame)
        self.assertEqual(reply["status"], "error")
        self.assertIsNone(self.args())

    def test_garbage_json(self):
        data = b"{not json"
        self.assertEqual(self.call(None, raw=struct.pack("<I", len(data)) + data)["status"], "error")


if __name__ == "__main__":
    unittest.main()
