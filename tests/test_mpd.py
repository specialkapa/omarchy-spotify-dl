"""Playback tests for bin/library against a throwaway MPD (null audio output).

Skipped when mpd/ffmpeg are missing. Never touches the user's MPD (uses port 6611).
Run: python3 -I tests/test_mpd.py
"""
import importlib.machinery
import importlib.util
import os
import shutil
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = "6611"


def load_library():
    loader = importlib.machinery.SourceFileLoader("library_mpd", os.path.join(HERE, "..", "bin", "library"))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader("library_mpd", loader))
    loader.exec_module(module)
    return module


def silent(path, title, seconds=120):
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                    "-t", str(seconds), "-metadata", f"title={title}", path], check=True)


@unittest.skipUnless(shutil.which("mpd") and shutil.which("ffmpeg"), "mpd/ffmpeg not installed")
class MPDPlayback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.music = os.path.join(cls.tmp.name, "music")
        os.makedirs(os.path.join(cls.music, "mix"))
        for i in range(1, 5):
            silent(os.path.join(cls.music, "mix", f"s{i}.mp3"), f"Silent {i}")
        conf = os.path.join(cls.tmp.name, "mpd.conf")
        with open(conf, "w") as f:
            f.write(f'music_directory "{cls.music}"\ndb_file "{cls.tmp.name}/db"\nstate_file "{cls.tmp.name}/state"\n'
                    f'bind_to_address "127.0.0.1"\nport "{PORT}"\nauto_update "no"\n'
                    'audio_output {\n type "null"\n name "null"\n}\n')
        cls.mpd = subprocess.Popen(["mpd", "--no-daemon", conf], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.environ.update(MPD_PORT=PORT, MPD_MUSIC_DIR=cls.music,
                          XDG_CACHE_HOME=os.path.join(cls.tmp.name, "cache"),
                          XDG_RUNTIME_DIR=cls.tmp.name)
        cls.lib = load_library()
        for _ in range(40):
            try:
                m = cls.lib.MPD()
                m.command("update")
                time.sleep(0.5)
                cls.lib.wait_for_update(m)
                m.close()
                break
            except OSError:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.mpd.terminate()
        cls.mpd.wait(5)
        cls.tmp.cleanup()

    def paths(self):
        return sorted(os.path.join(self.music, "mix", f) for f in os.listdir(os.path.join(self.music, "mix")))

    def test_play_from_index_and_transport(self):
        self.assertEqual(self.lib.play(self.music, self.paths()[:4] + ["/etc/passwd"], False, 2), 0)
        st = self.lib.status()
        self.assertEqual((st["playing"], st["title"], st["pos"], st["count"]), (True, "Silent 3", 2, 4))
        self.lib.ctl("next")
        self.assertEqual(self.lib.status()["title"], "Silent 4")
        self.lib.ctl("toggle")
        self.assertTrue(self.lib.status()["paused"])
        self.lib.ctl("toggle")
        self.assertFalse(self.lib.status()["paused"])
        self.lib.ctl("stop")
        self.assertEqual(self.lib.status(), {"playing": False})

    def test_shuffle_keeps_chosen_track_first(self):
        self.assertEqual(self.lib.play(self.music, self.paths()[:4], True, 1), 0)
        st = self.lib.status()
        self.assertEqual((st["title"], st["pos"]), ("Silent 2", 0))
        self.lib.ctl("stop")

    def test_unindexed_file_is_rescanned(self):
        fresh = os.path.join(self.music, "mix", "zz-fresh.mp3")
        silent(fresh, "Fresh", 30)
        self.assertEqual(self.lib.play(self.music, [fresh], False, 0), 0)
        self.assertEqual(self.lib.status()["title"], "Fresh")
        self.lib.ctl("stop")

    def test_paths_outside_root_rejected(self):
        self.assertEqual(self.lib.play(self.music, ["/etc/passwd"], False, 0), 1)

    def test_quoting(self):
        self.assertEqual(self.lib.mpd_quote('a "b" \\c'), '"a \\"b\\" \\\\c"')
        with self.assertRaises(self.lib.MPDError):
            self.lib.mpd_quote("bad\nadd x")


if __name__ == "__main__":
    unittest.main()
