#!/bin/sh
# Made-up stand-in for watchcat's worker script (test fixture, not OpenWrt's file): a notice line, the
# stock libraries, a monitor function with the host line and the timer test, and a second function
# (the reboot mode) with its own host loop, the shape the build looks for.
# Copyright (C) made-up notice of the fixture

. /lib/network/config.sh
. /lib/functions/network.sh

watchcat_monitor_network() {
	[ "$mm_iface_name" = "null" ] && mm_iface_name=""
	while true; do
		for host in $ping_hosts; do
			fake ping "$host"
		done

		[ "$((time_now - time_lastcheck_withinternet))" -ge "$failure_period" ] && {
			fake restart
		}
	done
}

watchcat_ping() {
	for host in $ping_hosts; do
		fake ping "$host"
	done
}
