"""Check Flutter assets, PNG payloads and iOS configuration. Python 3 only."""
from pathlib import Path
import json,struct,zlib,plistlib,sys
r=Path(__file__).resolve().parents[1];errors=[];report={}
for name,count in [('art-index',29186),('thumb-index',28463)]:
 d=json.loads((r/f'assets/muse/{name}.json').read_text());assert len(d)==count
 for key,m in d.items():
  p=r/m['asset']
  if not p.is_file():errors.append('Missing '+m['asset']);continue
  b=p.read_bytes()
  if len(b)!=m['l'] or b[:8]!=b'\x89PNG\r\n\x1a\n' or struct.unpack('>II',b[16:24])!=(m['w'],m['h']):errors.append('Invalid PNG '+key);continue
  at=8
  while at<len(b):
   n=struct.unpack('>I',b[at:at+4])[0];chunk=b[at+4:at+8+n];crc=struct.unpack('>I',b[at+8+n:at+12+n])[0]
   if zlib.crc32(chunk)&0xffffffff!=crc:errors.append('CRC mismatch '+key);break
   at+=n+12
 report[name]=len(d)
for n in ['lib/main.dart','lib/core.dart','lib/artwork.dart','lib/ads.dart','pubspec.yaml','pubspec.lock','ios/Podfile','ios/Runner.xcodeproj/project.pbxproj','ios/Runner.xcworkspace/contents.xcworkspacedata','ios/Runner/AppDelegate.swift','ios/Runner/SceneDelegate.swift']:
 if not (r/n).is_file():errors.append('Missing '+n)
for p in (r/'ios').rglob('*.plist'):
 try:plistlib.loads(p.read_bytes())
 except Exception:errors.append('Invalid plist '+str(p.relative_to(r)))
config=json.loads((r/'assets/muse/ad-config.json').read_text());info=plistlib.loads((r/'ios/Runner/Info.plist').read_bytes())
if info.get('GADApplicationIdentifier')!=config['iosAppId']:errors.append('AdMob app ID is not synchronized. Run tool/configure_ads.py.')
if 'FlutterGeneratedPluginSwiftPackage' in (r/'ios/Runner.xcodeproj/project.pbxproj').read_text():errors.append('Unexpected Swift Package Manager reference')
blockers=[]
if config['testMode']:blockers.append('AdMob test mode is enabled.')
if not config.get('iosRewardedId'):blockers.append('Production rewarded ad ID is missing.')
report.update(errors=errors,release_configuration_blockers=blockers)
(r/'AssetValidation.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
if errors or ('--release' in sys.argv and blockers):raise SystemExit(1)
