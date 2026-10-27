from pathlib import Path
import sys,json,hashlib,shutil,concurrent.futures,subprocess
source=Path(sys.argv[1]);R=Path(__file__).resolve().parents[1];A=R/'assets/muse';A.mkdir(parents=True,exist_ok=True)
res=source/'Assets/Muse/Resources/Muse'
for name in ['database.json','ad-config.json']:shutil.copy2(res/name,A/name)
for index,bank,folder in [('art-index.json','art.bank','art'),('thumb-index.json','thumbs.bank','thumbs')]:
 d=json.loads((res/index).read_text())
 with (source/'Assets/StreamingAssets/Muse'/bank).open('rb') as f:
  for key,m in d.items():
   h=hashlib.sha1(key.encode()).hexdigest();p=A/folder/h[:2]/(h+'.png');p.parent.mkdir(parents=True,exist_ok=True);f.seek(m['o']);b=f.read(m['l']);assert len(b)==m['l'] and b[:8]==b'\x89PNG\r\n\x1a\n';p.write_bytes(b);m['asset']=p.relative_to(R).as_posix()
 (A/index).write_text(json.dumps(d,separators=(',',':')));print(folder,len(d),flush=True)
(A/'fonts').mkdir(exist_ok=True)
for p in (res/'Fonts').glob('*.ttf'):shutil.copy2(p,A/'fonts'/p.name)
(A/'sound').mkdir(exist_ok=True)
def audio(i):subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(res/'sound'/f'Track {i}.ogg'),'-c:a','aac','-b:a','160k',str(A/'sound'/f'track{i}.m4a')],check=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as e:list(e.map(audio,range(1,5)))
print('Assets ready',flush=True)
