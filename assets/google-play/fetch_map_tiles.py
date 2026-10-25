"""Fetch only the small visible NYC tile set needed for the store map capture."""
from pathlib import Path
from urllib.request import Request, urlopen
from concurrent.futures import ThreadPoolExecutor

root = Path(__file__).resolve().parent
urls = [u for u in (root / 'tile-requests.txt').read_text().splitlines() if '/14/' in u]
def fetch(url):
    rel = url.split('tile.openstreetmap.org',1)[1].lstrip('/')
    target = root / 'tiles' / rel
    if target.exists(): return
    target.parent.mkdir(parents=True,exist_ok=True)
    req = Request(url,headers={'User-Agent':'OpenFamily-StoreArtwork/1.0 (https://foleyit.com)'})
    with urlopen(req,timeout=30) as response: target.write_bytes(response.read())
with ThreadPoolExecutor(max_workers=2) as pool:
    list(pool.map(fetch,urls))
print(f'{len(urls)} visible-area tiles ready; attribution: © OpenStreetMap contributors')
