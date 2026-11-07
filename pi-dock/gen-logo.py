import os
from PIL import Image, ImageDraw, ImageChops, ImageFont

d = "/usr/share/plymouth/themes/fairline"
os.makedirs(d, exist_ok=True)

W, H = 800, 960
NAVY = (13, 44, 94, 255)
WHITE = (255, 255, 255, 255)

img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
dr = ImageDraw.Draw(img)
shield = [(190, 40), (610, 40), (610, 165), (400, 650), (190, 165)]
dr.polygon(shield, fill=NAVY)

stripes = Image.new("RGBA", (W, H), (0, 0, 0, 0))
sd = ImageDraw.Draw(stripes)
for xc in [240, 300, 360]:
    sd.polygon([(xc - 30, 20), (xc + 30, 20), (xc + 80, 660), (xc + 20, 660)], fill=WHITE)

mask = Image.new("L", (W, H), 0)
ImageDraw.Draw(mask).polygon(shield, fill=255)
r, g, b, a = stripes.split()
a = ImageChops.multiply(a, mask)
stripes = Image.merge("RGBA", (r, g, b, a))
img.alpha_composite(stripes)

fp = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
if not os.path.exists(fp):
    fp = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
font = ImageFont.truetype(fp, 110)
text = "FAIRLINE"
spacing = 24
widths = [dr.textlength(ch, font=font) for ch in text]
total = sum(widths) + spacing * (len(text) - 1)
x = (W - total) / 2
for ch, cw in zip(text, widths):
    dr.text((x, 700), ch, font=font, fill=NAVY)
    x += cw + spacing

img.save(d + "/logo.png")

open(d + "/fairline.plymouth", "w").write("""[Plymouth Theme]
Name=Fairline
Description=Fairline boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/fairline
ScriptFile=/usr/share/plymouth/themes/fairline/fairline.script
""")

open(d + "/fairline.script", "w").write("""Window.SetBackgroundTopColor (1.0, 1.0, 1.0);
Window.SetBackgroundBottomColor (1.0, 1.0, 1.0);

screen_width = Window.GetWidth();
screen_height = Window.GetHeight();

theme_image = Image("logo.png");
image_width = theme_image.GetWidth();
image_height = theme_image.GetHeight();

target_width = screen_width * 0.42;
scale = target_width / image_width;
new_width = target_width;
new_height = image_height * scale;

resized_image = theme_image.Scale(new_width, new_height);
image_x = (screen_width - new_width) / 2;
image_y = (screen_height - new_height) / 2;

sprite = Sprite(resized_image);
sprite.SetPosition(image_x, image_y, -100);
""")
print("OK: logo and theme written to", d)
