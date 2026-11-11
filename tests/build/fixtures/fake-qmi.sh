#!/bin/sh
# Made-up stand-in for a netifd protocol handler (test fixture, not OpenWrt's file): one mode set
# and one network scan after it, like the shape the build looks for.
proto_fake_setup() {
	[ -n "$modes" ] && {
		fake -s -d "$device" --set-network-modes "$modes" > /dev/null 2>&1
		sleep 3
		# scan
		fake -s -d "$device" -t 30000 --network-scan > /dev/null 2>&1
	}
	echo "Waiting for network registration"
}
