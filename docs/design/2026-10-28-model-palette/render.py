from pathlib import Path
import re
from PIL import Image,ImageDraw,ImageFont
root=Path(__file__).resolve().parents[3]
colors=dict(re.findall(r'"([^"\n]+)": "(#[a-f0-9]{6})"',(root/'Sources/CodexTokenBar/ModelUsagePresentation.swift').read_text()))
im=Image.new('RGB',(1440,960),'#101317');d=ImageDraw.Draw(im)
f='/System/Library/Fonts/STHeiti Medium.ttc'
font=lambda n:ImageFont.truetype(f,n)
d.text((64,44),'模型配色',font=font(36),fill='#f4f5f7')
d.text((64,98),'默认色预览 · 实际使用统一模型色表 · 不是运行数据截图',font=font(19),fill='#a8afb8')
rows=[('gpt-6-astra','Astra','淡绿'),('gpt-6.1-sol','6.1 Sol','橙红'),('gpt-6-luna','6 Luna','天蓝'),('claude-opus','Claude Opus','柔紫'),('claude-sonnet','Claude Sonnet','暖杏'),('claude-haiku','Claude Haiku','青绿')]
for left,bg,fg,muted in [(40,'#1a1f26','#f3f5f7','#a7aeb8'),(744,'#f4f5f7','#202730','#64707c')]:
 d.rounded_rectangle((left,154,left+656,812),radius=24,fill=bg)
 d.text((left+30,180),'深色背景' if left==40 else '浅色背景',font=font(19),fill=muted)
 for i,(key,name,label) in enumerate(rows):
  y=243+i*86; c=colors[key]
  d.ellipse((left+30,y,left+54,y+24),fill=c)
  d.text((left+72,y-3),name,font=font(25),fill=fg)
  d.text((left+72,y+32),label+'  '+c.upper(),font=font(16),fill=muted)
  d.rounded_rectangle((left+442,y+7,left+614,y+19),radius=6,fill=c)
d.text((64,855),'同一模型在用量、曲线和速度条中使用同色；Claude 各版本按模型家族配色。',font=font(20),fill='#e0e4e8')
d.text((64,896),'旧系列使用低饱和色，避免与 Astra / 6.1 Sol / 6 Luna 争抢注意。',font=font(18),fill='#9ca5b0')
im.save(root/'docs/design/2026-10-28-model-palette/palette-preview.png')
