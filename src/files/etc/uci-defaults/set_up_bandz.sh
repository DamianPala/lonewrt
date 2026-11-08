#!/bin/sh
# Replaces luci-app-modemband's first-boot script of the same name: it ran `modemband.sh getbands`
# inside S10boot, on the LuCI AT port, outside /tmp/lw-at.lock and with no time limit, so a silent
# modem could hold up the first boot (SPEC R8, R12a, D28). The band target lives in lonewrt.modem.bands;
# the LuCI modemband page reads the modem itself and needs nothing from here.
exit 0
