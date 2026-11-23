#!/bin/sh
# Made-up stand-in for a netifd protocol handler (test fixture, not OpenWrt's file): a notice line,
# one mode set and one network scan after it, a registration call, a negotiation block between its
# start and end anchor lines, a teardown function, the 464XLAT and IPv6 settings lines and two blocks
# that open like the IPv4 child block (the second one ends the setup), the shape the build looks for.
# Copyright (C) made-up notice of the fixture
proto_fake_setup() {
	[ -n "$modes" ] && {
		fake -s -d "$device" --set-network-modes "$modes" > /dev/null 2>&1
		sleep 3
		# scan
		fake -s -d "$device" -t 30000 --network-scan > /dev/null 2>&1
	}
	uqmi -s -d "$device" -t 20000 --network-register > /dev/null 2>&1
	echo "Waiting for network registration"
	echo "Starting network $interface"
	fake start
	echo "Setting up $ifname"
	[ -n "$pdh_4" ] && {
		fake publish4
	}
	[ -n "$pdh_6" ] && {
		if [ -z "$dhcpv6" -o "$dhcpv6" = 0 ]; then
			fake static6
		else
			fake child6
			[ "$pdptype" = "ipv4v6" ] && json_add_string iface_464xlat "0"
		fi
	}
	[ -n "$pdh_4" ] && {
		fake child4
	}
}
qmi_wds_stop() {
	fake stop
}
