"""Synchronize Dart ad configuration and the iOS app identifier."""
from pathlib import Path
import argparse,json,plistlib,re
p=argparse.ArgumentParser();g=p.add_mutually_exclusive_group(required=True);g.add_argument('--test',action='store_true');g.add_argument('--production',action='store_true');p.add_argument('--app-id');p.add_argument('--interstitial-id');p.add_argument('--rewarded-id');a=p.parse_args()
r=Path(__file__).resolve().parents[1];path=r/'assets/muse/ad-config.json';d=json.loads(path.read_text())
for arg,key in [(a.app_id,'iosAppId'),(a.interstitial_id,'iosInterstitialId'),(a.rewarded_id,'iosRewardedId')]:
 if arg:d[key]=arg.strip()
d['testMode']=not a.production
if not re.fullmatch(r'ca-app-pub-\d{16}~\d{10}',d.get('iosAppId','')):p.error('Supply a valid iOS app ID with --app-id.')
if a.production:
 for key in ['iosInterstitialId','iosRewardedId']:
  if not re.fullmatch(r'ca-app-pub-\d{16}/\d{10}',d.get(key,'')) or '3940256099942544' in d[key]:p.error('Supply real production ad unit IDs, including --rewarded-id.')
f=r/'ios/Runner/Info.plist';info=plistlib.loads(f.read_bytes());info['GADApplicationIdentifier']=d['iosAppId'];f.write_bytes(plistlib.dumps(info,sort_keys=False));path.write_text(json.dumps(d,indent=2)+'\n');print('Ad configuration synchronized:', 'test units' if d['testMode'] else 'production units')
