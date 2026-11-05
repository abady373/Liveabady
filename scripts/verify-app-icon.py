"""Verify the final actool output, rather than source asset names alone."""
from pathlib import Path
import plistlib
import sys

bundle = Path(sys.argv[1])
with (bundle / 'Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
primary = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
assert primary.get('CFBundleIconName') == 'AppIcon', 'Missing AppIcon declaration'
names = primary.get('CFBundleIconFiles', [])
assert names, 'Missing iPhone icon file declarations'
assert (bundle / 'Assets.car').is_file(), 'Missing compiled asset catalog'
for name in names:
    assert list(bundle.glob(f'{name}*.png')), f'Missing compiled PNG for {name}'
assert list(bundle.glob('AppIcon60x60*png')), 'Missing home-screen icon PNG'
print('PASS: compiled AppIcon, iPhone PNG files and CFBundleIcons are present')
print(f'App version: {info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]})')
