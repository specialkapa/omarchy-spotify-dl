"""Unit tests for bin/spotify-dl naming and link parsing.

Run:  python3 -I tests/test_spotify_dl.py
"""
import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("spotify_dl", os.path.join(HERE, "..", "bin", "spotify-dl"))
_spec = importlib.util.spec_from_loader("spotify_dl", _loader)
sd = importlib.util.module_from_spec(_spec)
_loader.exec_module(sd)


class Naming(unittest.TestCase):
    def check(self, artists, title, expected):
        self.assertEqual(sd.file_stem(artists, title), expected)

    def test_single_artist(self):
        self.check(["Rick Astley"], "Never Gonna Give You Up", "rick astley - never gonna give you up")

    def test_extra_artists_become_feat(self):
        self.check(["KAROL G", "Judeline", "rusowsky"], "BbY WOW", "karol g - bby wow (feat. judeline, rusowsky)")

    def test_existing_feat_not_duplicated(self):
        self.check(["Olivia Rodrigo", "Chappell Roan"], "expectations (feat. Chappell Roan)",
                   "olivia rodrigo - expectations (feat. chappell roan)")

    def test_with_and_ft_normalised(self):
        self.check(["Sam Fender", "Olivia Dean"], "Rein Me In (with Olivia Dean)",
                   "sam fender - rein me in (feat. olivia dean)")
        self.check(["ANOTR", "54 Ultra"], "Talk To You (ft. 54 Ultra)", "anotr - talk to you (feat. 54 ultra)")

    def test_artist_named_in_title_not_repeated(self):
        self.check(["PinkPantheress", "Zara Larsson"], "Stateside + Zara Larsson",
                   "pinkpantheress - stateside + zara larsson")

    def test_other_parentheses_kept(self):
        self.check(["HUGEL", "SOLTO (FR)"], "Jamaican (Bam Bam)", "hugel - jamaican (bam bam) (feat. solto (fr))")

    def test_illegal_characters(self):
        self.check(["AC/DC"], 'What? "Now": <x>|y', "ac dc - what now x y")

    def test_markup_and_control_chars(self):
        stem = sd.file_stem(["<img src=x>"], "a\x00b\nc")
        self.assertNotIn("/", stem)
        self.assertNotIn("\x00", stem)
        self.assertNotIn("\n", stem)

    def test_length_capped(self):
        self.assertLessEqual(len(sd.file_stem(["a" * 400], "b" * 400).encode()), 180)

    def test_no_artists(self):
        self.check([], "Song", "unknown artist - song")


class Tags(unittest.TestCase):
    def test_primary_artist_and_feat_title_keep_case(self):
        self.assertEqual(sd.standard_names(["Sam Fender", "Olivia Dean"], "Rein Me In (with Olivia Dean)"),
                         ("Sam Fender", "Rein Me In (feat. Olivia Dean)"))
        self.assertEqual(sd.standard_names(["KAROL G", "Judeline"], "BbY WOW"), ("KAROL G", "BbY WOW (feat. Judeline)"))


class GenreFallback(unittest.TestCase):
    def genres(self, track="", artist="", fail=False):
        g = sd.Genres()
        def boom(*a, **k):
            raise OSError("offline")
        g.from_track = boom if fail else (lambda a, t: track)
        g.from_artist = boom if fail else (lambda a: artist if a == "Main" else "")
        return g

    def test_order(self):
        self.assertEqual(self.genres(track="Pop", artist="Rock").lookup(["Main"], "t", "Jazz", "Unknown"), "Pop")
        self.assertEqual(self.genres(artist="Rock").lookup(["Main"], "t", "Jazz", "Unknown"), "Jazz")
        self.assertEqual(self.genres(artist="Rock").lookup(["Main"], "t", "", "Unknown"), "Rock")
        self.assertEqual(self.genres().lookup(["Main"], "t", "", "Unknown"), "Unknown")
        self.assertEqual(self.genres().lookup(["Main"], "t", "", ""), "")

    def test_featured_artist_used_when_primary_unknown(self):
        g = self.genres()
        g.from_artist = lambda a: "Rap/Hip Hop" if a == "Feat" else ""
        self.assertEqual(g.lookup(["Main", "Feat"], "t", "", "Unknown"), "Rap/Hip Hop")

    def test_network_errors_fall_through_to_default(self):
        self.assertEqual(self.genres(fail=True).lookup(["Main"], "t", "", "Unknown"), "Unknown")


class Links(unittest.TestCase):
    def test_spotify(self):
        cases = {
            "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC": ("spotify", "track", "4uLU6hMCjMI75M1A2tKUQC"),
            "https://open.spotify.com/intl-de/track/4uLU6hMCjMI75M1A2tKUQC?si=abc": ("spotify", "track", "4uLU6hMCjMI75M1A2tKUQC"),
            "open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M": ("spotify", "playlist", "37i9dQZF1DXcBWIGoYBM5M"),
            "  spotify:album:4LH4d3cOWNNsVw41Gqt2kv \n": ("spotify", "album", "4LH4d3cOWNNsVw41Gqt2kv"),
        }
        for link, expected in cases.items():
            self.assertEqual(sd.parse_link(link), expected, link)

    def test_youtube(self):
        cases = {
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ": ("youtube", "track", "dQw4w9WgXcQ"),
            "https://youtube.com/watch?feature=share&v=dQw4w9WgXcQ&t=42": ("youtube", "track", "dQw4w9WgXcQ"),
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ&index=1": ("youtube", "track", "dQw4w9WgXcQ"),
            "https://youtu.be/dQw4w9WgXcQ?si=x": ("youtube", "track", "dQw4w9WgXcQ"),
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ": ("youtube", "track", "dQw4w9WgXcQ"),
            "https://m.youtube.com/shorts/dQw4w9WgXcQ": ("youtube", "track", "dQw4w9WgXcQ"),
            "https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI":
                ("youtube", "playlist", "PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI"),
            "https://music.youtube.com/playlist?list=OLAK5uy_kNWWfKMGKkk4NZlX8H5z8FRn9wpzS9wl8":
                ("youtube", "album", "OLAK5uy_kNWWfKMGKkk4NZlX8H5z8FRn9wpzS9wl8"),
            "https://music.youtube.com/browse/MPREb_7ltM34kr0mH": ("youtube", "album", "MPREb_7ltM34kr0mH"),
        }
        for link, expected in cases.items():
            self.assertEqual(sd.parse_link(link), expected, link)

    def test_invalid(self):
        for link in ["", "https://evil.example/track/4uLU6hMCjMI75M1A2tKUQC",
                     "https://open.spotify.com/artist/0gxyHStUsqpMadRV0Di1Qt",
                     "https://open.spotify.com/track/short", "spotify:track:4uLU6hMCjMI75M1A2tKUQC;rm -rf ~",
                     "https://www.youtube.com/watch?v=short", "https://www.youtube.com/@channel",
                     "https://evil.example/watch?v=dQw4w9WgXcQ", "https://www.youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
                     "https://www.youtube.com/playlist?list=RDdQw4w9WgXcQ"]:
            with self.assertRaises(ValueError, msg=link):
                sd.parse_link(link)


class YouTubeNames(unittest.TestCase):
    def names(self, title, channel="Some Channel", **extra):
        return sd.youtube_names({"title": title, "channel": channel, **extra})

    def test_official_video(self):
        self.assertEqual(self.names("Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)"),
                         (["Rick Astley"], "Never Gonna Give You Up"))

    def test_bare_feat_after_junk(self):
        self.assertEqual(self.names("Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers"),
                         (["Daft Punk", "Pharrell Williams", "Nile Rodgers"], "Get Lucky"))
        self.assertEqual(self.names("Daft Punk - Get Lucky (Official Video) feat. Pharrell Williams and Nile Rodgers"),
                         (["Daft Punk", "Pharrell Williams", "Nile Rodgers"], "Get Lucky"))

    def test_bracketed_feat_kept_for_standard_names(self):
        artists, title = self.names("Olivia Rodrigo - expectations (feat. Chappell Roan) [Lyrics]")
        self.assertEqual(sd.file_stem(artists, title), "olivia rodrigo - expectations (feat. chappell roan)")

    def test_artist_field_with_feat_and_x(self):
        self.assertEqual(self.names("Calvin Harris x Dua Lipa - One Kiss | Official Video")[0], ["Calvin Harris", "Dua Lipa"])

    def test_no_dash_uses_channel(self):
        self.assertEqual(self.names("Blinding Lights (Official Audio)", channel="The Weeknd - Topic"),
                         (["The Weeknd"], "Blinding Lights"))
        self.assertEqual(self.names("Song", channel="TaylorSwiftVEVO")[0], ["TaylorSwift"])

    def test_metadata_fields_win(self):
        self.assertEqual(self.names("whatever - junk", track="Real Title", artists=["A", "B"]), (["A", "B"], "Real Title"))

    def test_markup_and_control_chars_bounded(self):
        artists, title = self.names("<img src=x> - a\x00b" + "c" * 900)
        self.assertNotIn("\x00", title)
        self.assertLessEqual(len(title), sd.MAX_FIELD)


class Entity(unittest.TestCase):
    def test_playlist_split_and_bounds(self):
        entity = {"name": "Mix", "trackList": [
            {"title": "BbY WOW", "subtitle": "KAROL G,\xa0Judeline", "duration": 180000},
            {"title": "", "subtitle": "x"},
            "garbage",
        ]}
        name, tracks = sd.tracks_from_entity("playlist", entity)
        self.assertEqual(name, "Mix")
        self.assertEqual(len(tracks), 1)
        self.assertEqual(tracks[0]["artists"], ["KAROL G", "Judeline"])
        self.assertEqual(tracks[0]["duration"], 180)

    def test_comma_in_artist_name_preserved(self):
        _, tracks = sd.tracks_from_entity("album", {"name": "A", "trackList": [
            {"title": "T", "subtitle": "Tyler, The Creator,\xa0Kali Uchis"}]})
        self.assertEqual(tracks[0]["artists"], ["Tyler, The Creator", "Kali Uchis"])


if __name__ == "__main__":
    unittest.main()
