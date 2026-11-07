#!/usr/bin/env python3
p = "/home/pi/.config/labwc/rc.xml"
s = open(p).read()

rules = (
    '    <windowRule identifier="grafana-kiosk">\n'
    '      <action name="Maximize" />\n'
    '    </windowRule>\n'
    '    <windowRule identifier="signalk-kiosk">\n'
    '      <action name="Maximize" />\n'
    '    </windowRule>\n'
)

if "grafana-kiosk" in s:
    print("already inserted, skipping")
else:
    assert "  </windowRules>" in s, "no closing windowRules tag found"
    s = s.replace("  </windowRules>", rules + "  </windowRules>", 1)
    open(p, "w").write(s)
    print("inserted OK")
