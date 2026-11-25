"""Generate golden values from the Kodi addon's own Python functions."""
import json, sys, types
addon = sys.argv[1]
# Stub Kodi modules.
for name in ['xbmc', 'xbmcgui', 'xbmcvfs', 'xbmcaddon', 'xbmcplugin']:
    m = types.ModuleType(name); sys.modules[name] = m
sys.modules['xbmc'].LOGINFO = 1; sys.modules['xbmc'].LOGWARNING = 2; sys.modules['xbmc'].LOGERROR = 3
sys.modules['xbmc'].log = lambda *a, **k: None
class _Addon:
    def __init__(self, *a, **k): pass
    def getAddonInfo(self, k): return '/tmp/addon'
    def getSettingString(self, k): return ''
    def getSettingBool(self, k): return False
    def getLocalizedString(self, k): return ''
sys.modules['xbmcaddon'].Addon = _Addon
sys.modules['xbmcvfs'].translatePath = lambda p: p
sys.modules['xbmcvfs'].exists = lambda p: False
sys.modules['xbmcgui'].Dialog = object
sys.modules['xbmcgui'].DialogProgress = object
sys.modules['xbmcgui'].NOTIFICATION_ERROR = 0
sys.modules['xbmcgui'].NOTIFICATION_WARNING = 0
sys.argv = ['plugin://x', '1', '']
sys.path.insert(0, addon)
import torbox_common as c, torbox_identify as i, torbox_sync as s
from difflib import SequenceMatcher

names = [
 '[ OxTorrent.com ] Game.Of.Thrones.Integral.(S01 à S08).MULTI.1080p.BluRay.HDLight.AC3.x264',
 'The.Office.Complete.Series.1080p', 'Breaking Bad Collection (2008)', 'Dune.2021.1080p',
 '1917.2019.1080p.BluRay', 'Integral.Man.2019', 'Frieren - Sousou no Frieren S01',
 'The.Bear.S03.1080p.WEB', 'Shōgun (2024) Season 1 [1080p]', 'Oppenheimer.2023.2160p.UHD.BluRay.x265-GROUP.mkv',
 'Le Bureau des Légendes - Saison 2', 'Die.Hard.1988.REMASTERED', 'Blade Runner 2049 (2017)',
 'Some_Movie_Name_2010_720p', '{Tag} [Other] Spirited Away', '2012', 'Taxi Driver 1976 Directors.Cut',
 'Mr. Robot S01-S04 Complete', 'Avatar - The Way of Water / Avatar 2', 'Doctor.Who.2005.1x05.mkv',
]
files = ['Show.S01E02.mkv', 'Show.1x05.mkv', '08 - Puines.mkv', 'Show - E21 [BD].mkv', 'Show.S04E01.mkv',
         '1080p.mkv', 'Show.2019.E02.1080p.mkv', 'Episode 7.mp4', 'ep12.mkv', '3_title.mkv', 's2e3.avi', '123abc.mkv']
texts = ['The Lord of the Rings: The Two Towers', 'Amélie', 'Fast & Furious', 'the', 'Les Misérables', 'ＡＢＣ　ｄｅｆ', 'Pokémon: The Movie']
pairs = [('game of thrones integral', 'game of thrones'), ('dune', 'dune part two'), ('frieren', "frieren beyond journey s end"),
         ('abcabcabc', 'cabcab'), ('the office', 'office'), ('x'*250 + 'y', 'x'*240 + 'yz'), ('', '')]
out = {
  'parse': {n: i.parse_release_name(n) for n in names},
  'queries': {},
  'normalize': {t: i._normalize(t) for t in texts},
  'ratio': [[a, b, SequenceMatcher(None, a, b).ratio()] for a, b in pairs],
  'episode': {f: list(c.extract_episode_info(f)) for f in files},
  'bare': {f: c.extract_bare_episode(f) for f in files},
  'guess': {n: c.guess_season(n) for n in names + ['Season 2', 'S03', 'Stagione 4']},
}
import re
for n in names:
    t = i.parse_release_name(n)['title']
    q = [t] + [p.strip() for p in re.split(r'\s+-\s+|\s*/\s*', t) if p.strip()][:3]
    out['queries'][n] = list(dict.fromkeys(q))
root = 'Game.Of.Thrones.Integral.(S01 à S08).MULTI'
items = [
  {'name': '08 - Puines.mkv', 'path': '/' + root + '/Game.Of.Thrones.Saison.3.MULTI.1080p/08 - Puines.mkv', 'size': 5},
  {'name': 'Show - E21 [BD].mkv', 'path': '/' + root + '/Show - E21 [BD].mkv', 'size': 9},
  {'name': 'Show.S04E01.mkv', 'path': '/' + root + '/Show.S04E01.mkv', 'size': 7},
  {'name': '1080p.mkv', 'path': '/' + root + '/1080p.mkv', 'size': 3},
]
cases = [{}, {'season': 2}, {'season': 3, 'force_season': True}, {'title': 'X', 'type': 'movie'}, {'type': 'movie'}]
out['number'] = []
for ov in cases:
    numbered = s.number_files(root, ov, items)
    out['number'].append({'override': ov, 'result': [[n[1], n[2], n[3]] for n in numbered]})
out['root'] = root; out['items'] = items
entries = [{'title': 'Game of Thrones', 'type': 'tvshow', 'tmdb_id': '1399'}, {'title': 'Dune', 'type': 'movie', 'imdb_id': 'tt1'},
           {'title': 'The Office', 'year': 2005}, {'title': 'Amélie', 'type': 'movie', 'year': 2001}, {'title': 'X', 'type': 'weird', 'tvdb_id': 5},
           {'title': 'Y', 'tmdb_id': 42}]
out['keys'] = [[e, s.title_key(e)] for e in entries]
results = [{'name': 'Frieren: Beyond Journey\'s End', 'original_name': '葬送のフリーレン', 'first_air_date': '2023-09-29'},
           {'title': 'Dune', 'original_title': 'Dune', 'release_date': '2021-09-15'},
           {'title': 'Dune: Part Two', 'release_date': '2024-02-27'},
           {'title': 'Game of Thrones', 'release_date': ''}]
out['score'] = []
for q, y, mt in [('Frieren', 2023, 'tvshow'), ('Dune', 2021, 'movie'), ('Dune', None, 'movie'), ('Game of Thrones', 2011, 'tvshow')]:
    for r in results:
        out['score'].append([q, y, mt, r, list(i._score(q, y, r, mt))])
print(json.dumps(out, ensure_ascii=False, indent=1))
