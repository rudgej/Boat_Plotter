#!/usr/bin/env python3
import shutil, re

conf = "/home/pi/.opencpn/opencpn.conf"
shutil.copy2(conf, conf + ".bak-chartfix")

s = open(conf).read()

new_section = (
    "[ChartDirectories]\n"
    "ChartDir1=/home/pi/Charts^\n"
)

if "[ChartDirectories]" in s:
    print("section already present - updating")
    # Replace existing ChartDir1 within section, or add
    m = re.search(r"\[ChartDirectories\].*?(?=\n\[|\Z)", s, re.DOTALL)
    block = m.group(0)
    if "ChartDir1=" in block:
        s = s.replace(block, "[ChartDirectories]\nChartDir1=/home/pi/Charts^\n", 1)
        print("updated ChartDir1")
    else:
        s = s.replace("[ChartDirectories]", new_section.rstrip("\n"), 1)
        print("added ChartDir1")
else:
    # Insert after the [Directories] section's InitChartDir line
    if "InitChartDir=/home/pi/Charts" in s:
        s = s.replace("InitChartDir=/home/pi/Charts",
                      "InitChartDir=/home/pi/Charts\n" + new_section.rstrip("\n"), 1)
        print("inserted [ChartDirectories] after InitChartDir")
    else:
        s = s + "\n" + new_section
        print("appended [ChartDirectories]")

open(conf, "w").write(s)
print("done")
