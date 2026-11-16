"""Tests for bin/library's ID3 reader and scan.  Run: python3 -I tests/test_library.py"""
import importlib.machinery
import importlib.util
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("library", os.path.join(HERE, "..", "bin", "library"))
_spec = importlib.util.spec_from_loader("library", _loader)
lib = importlib.util.module_from_spec(_spec)
_loader.exec_module(lib)


def make_mp3(path, **tags):
    cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=22050:cl=mono",
           "-t", "0.2", "-id3v2_version", "3"]
    for k, v in tags.items():
        cmd += ["-metadata", f"{k}={v}"]
    subprocess.run(cmd + [path], check=True)


class Library(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.environ["XDG_CACHE_HOME"] = os.path.join(self.root, ".cache")
        lib.CACHE_DIR = os.path.join(self.root, ".cache", "x")
        lib.CACHE_FILE = os.path.join(lib.CACHE_DIR, "library.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_unicode_tags_have_no_bom(self):
        os.makedirs(os.path.join(self.root, "mix"))
        p = os.path.join(self.root, "mix", "adéla - nicole kidman.mp3")
        make_mp3(p, title="Nicole Kidman", artist="ADÉLA", artists="ADÉLA; Ελληνικά", genre="Pop", grouping="Today’s Top Hits")
        t = lib.track_info(p, self.root)
        self.assertEqual(t["artist"], "ADÉLA")
        self.assertEqual(t["artists"], ["ADÉLA", "Ελληνικά"])
        self.assertEqual(t["grouping"], "Today’s Top Hits")
        self.assertEqual(t["genre"], "Pop")
        for v in [t["title"], t["artist"], t["grouping"], *t["artists"]]:
            self.assertNotIn("﻿", v)

    def test_untagged_file_falls_back_to_name_and_folder(self):
        os.makedirs(os.path.join(self.root, "road trip"))
        p = os.path.join(self.root, "road trip", "some artist - some song.mp3")
        make_mp3(p)
        t = lib.track_info(p, self.root)
        self.assertEqual((t["artist"], t["title"], t["grouping"]), ("some artist", "some song", "road trip"))

    def test_scan_uses_cache_and_skips_hidden(self):
        make_mp3(os.path.join(self.root, "a - b.mp3"), title="B", artist="A")
        os.makedirs(os.path.join(self.root, ".spotify-dl-tmp"))
        make_mp3(os.path.join(self.root, ".spotify-dl-tmp", "dl.mp3"))
        first = lib.scan(self.root)
        self.assertEqual([t["title"] for t in first["tracks"]], ["B"])
        self.assertTrue(os.path.exists(lib.CACHE_FILE))
        self.assertEqual(lib.scan(self.root), first)

    def test_play_rejects_paths_outside_root(self):
        self.assertEqual(lib.play(self.root, ["/etc/passwd"], False, 0), 1)


if __name__ == "__main__":
    unittest.main()
