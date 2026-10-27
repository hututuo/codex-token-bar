#!/usr/bin/env python3
"""Compose README loops from saved production-component captures, using ffmpeg."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'Assets/showcase'

def run(*args):
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *map(str,args)], check=True)

def loop(name, states, hold=3):
    with tempfile.TemporaryDirectory(prefix='tokenbar-docs-') as tmp:
        inputs=[]
        for state in states:
            path=ASSETS / state
            if not path.is_file(): raise FileNotFoundError(path)
            inputs += ['-loop','1','-framerate','12','-t',str(hold),'-i',path]
        filters=[f'[{i}:v]format=yuv420p,setsar=1[v{i}]' for i in range(len(states))]
        previous='v0'
        for i in range(1,len(states)):
            out=f'blend{i}'
            filters.append(f'[{previous}][v{i}]xfade=transition=fade:duration=0.25:offset={i*(hold-.25)}[{out}]')
            previous=out
        mp4=Path(tmp)/'loop.mp4'
        run(*inputs,'-filter_complex',';'.join(filters),'-map',f'[{previous}]','-c:v','libx264','-crf','20','-pix_fmt','yuv420p',mp4)
        run('-i',mp4,'-filter_complex','fps=12,scale=1000:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle','-loop','0',ASSETS/f'{name}.gif')

loop('displays',['displays-rest.png','displays-hover.png','displays-detail.png','displays-right.png'])
loop('usage',['usage-24h.png','usage-7d.png','usage-30d.png'])
run('-i',ASSETS/'cache-reminder.mp4','-filter_complex','fps=10,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle','-loop','0',ASSETS/'cache-reminder.gif')
print('Created displays.gif, usage.gif, cache-reminder.gif')
