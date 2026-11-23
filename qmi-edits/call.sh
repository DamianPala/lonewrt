	echo "Starting network $interface"

	# lonewrt (SPEC R73 to R73o): the IP family negotiation, in lw_negotiate above
	lw_negotiate || return 1

