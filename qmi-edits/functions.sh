# lonewrt's own text (MIT, SPEC R12d, D172): the functions that qmi-handler.sh puts into the image's
# qmi.sh in front of qmi_wds_stop. Check with: shellcheck -s sh -e SC2034,SC2086,SC2154,SC3043. They run inside proto_qmi_setup and read its variables (device,
# apn, v6apn, profile, v6profile, auth, username, password, autoconnect, pdptype, interface) and set
# its cid_4, pdh_4, cid_6 and pdh_6, as the code they replace did. BusyBox ash: POSIX sh only.

LW_QMI_RECORD=/etc/lw-wwan-ptype
# R73h: the negotiation deadline in seconds, and the time kept back at its end for the cleanup
LW_NEG_SECONDS=60
LW_RESERVE=8

# lw_dbg MESSAGE: one syslog line at daemon.debug, only at the debug level (R29c, R77a). Never the
# login, never a raw profile (R73o).
lw_dbg() {
	[ -n "$lw_debug" ] || {
		lw_debug=0
		[ "$(uci -q get lonewrt.log.level)" != debug ] || lw_debug=1
	}
	[ "$lw_debug" = 1 ] || return 0
	logger -t lw-qmi -p daemon.debug "$*"
}

# lw_now: whole seconds of a clock that does not jump (the uptime file of common.sh) in lw_t
lw_now() {
	local up
	read -r up _ <"${LW_UPTIME_FILE:-/proc/uptime}"
	lw_t=${up%%.*}
	[ -n "$lw_t" ] || lw_t=0
}

# lw_left: whole seconds before the negotiation deadline in lw_s (R73h)
lw_left() {
	lw_now
	lw_s=$((lw_dl - lw_t))
	[ "$lw_s" -gt 0 ] || lw_s=0
}

# lw_q MS ARGS...: one uqmi call of this start, with uqmi's own -t and a limit around it, cut to the
# time left (R73h, R12d). The answer is in lw_out, the exit status is the return value; 124 when no
# time is left.
lw_q() {
	local ms=$1 rc=0
	shift
	lw_left
	lw_out=
	[ "$lw_s" -gt 0 ] || return 124
	[ "$ms" -le $((lw_s * 1000)) ] || ms=$((lw_s * 1000))
	lw_out=$(timeout -k 1 $((ms / 1000 + 1)) uqmi -s -d "$device" -t "$ms" "$@" 2>/dev/null </dev/null) || rc=$?
	return "$rc"
}

# lw_qa MS ARGS...: like lw_q for a call of an attempt, which leaves the time for the cleanup (R73h)
lw_qa() {
	local ms=$1 room
	shift
	lw_left
	room=$(((lw_s - LW_RESERVE) * 1000))
	if [ "$room" -le 0 ]; then
		lw_out=
		return 124
	fi
	[ "$ms" -le "$room" ] || ms=$room
	lw_q "$ms" "$@"
}

# lw_say TEXT: the stock handler's line when forced (the log is the one of the stock handler), else
# kept for the end of a start whose steps all failed
lw_say() {
	if [ "$lw_forced" = 1 ]; then
		echo "$1"
	else
		lw_why=$1
	fi
}

# lw_release CID: give back a client of this start (R73e)
lw_release() {
	lw_q 1000 --set-client-id wds,"$1" --release-client-id wds
}

# lw_profile_read [c]: profile 1 of the modem in lw_p_apn, lw_p_type and lw_p_off; fails when the
# modem does not give it (R73o). With c the call is a cleanup call.
lw_profile_read() {
	local q=lw_qa j
	[ "${1:-}" != c ] || q=lw_q
	$q 1000 --get-profile-settings 3gpp,1 || return 1
	j=$lw_out
	lw_p_type=$(jsonfilter -s "$j" -e '@["pdp-type"]' 2>/dev/null) || return 1
	[ -n "$lw_p_type" ] || return 1
	lw_p_apn=$(jsonfilter -s "$j" -e '@.apn' 2>/dev/null) || lw_p_apn=
	lw_p_off=$(jsonfilter -s "$j" -e '@["apn-disabled"]' 2>/dev/null) || lw_p_off=
	return 0
}

# lw_p_is TYPE: the profile read last holds this APN and TYPE and is enabled (R73f)
lw_p_is() {
	[ "$lw_p_apn" = "$apn" ] && [ "$lw_p_type" = "$1" ] &&
		[ "$lw_p_off" != 1 ] && [ "$lw_p_off" != true ]
}

# lw_sim: the ICCID of the SIM in lw_sim_id ("-" when unknown, as on the MF289F, whose modem answers
# "Not supported"); it only tells one SIM from another in the record, and neither it nor its failure
# is logged. An unknown SIM matches nothing (lw_repair)
lw_sim() {
	lw_sim_id=
	if lw_qa 1000 --get-iccid; then
		lw_sim_id=$(printf '%s' "$lw_out" | tr -cd '0-9A-Za-z')
	fi
	[ -n "$lw_sim_id" ] || lw_sim_id=-
}

# lw_rec_read: the flash record "KIND TYPE APN SIM" in lw_rk, lw_rt, lw_ra, lw_rs; fails without one.
# KIND is ok (the type the last start came up with) or change (a start began to change the type).
lw_rec_read() {
	lw_rk='' lw_rt='' lw_ra='' lw_rs=''
	[ -f "$LW_QMI_RECORD" ] || return 1
	read -r lw_rk lw_rt lw_ra lw_rs <"$LW_QMI_RECORD" || [ -n "$lw_rk" ]
}

# lw_rec_put KIND TYPE: the record, written at once and only when it changes; a cut write leaves the
# old or the new file (R73n)
lw_rec_put() {
	local want="$1 $2 ${apn:--}"
	lw_rec_read || :
	[ "$lw_rk $lw_rt $lw_ra" != "$want" ] || return 0
	lw_sim
	{ printf '%s %s\n' "$want" "$lw_sim_id" >"$LW_QMI_RECORD.tmp" &&
		mv -f "$LW_QMI_RECORD.tmp" "$LW_QMI_RECORD"; } || lw_dbg "the profile record was not written"
}

# lw_profile_set TYPE: profile 1 holds the APN and TYPE for the calls of this step. It is written
# only when it differs or is disabled (R73f); an unreadable profile is written as the stock handler
# does and counts as unverified (R73o), so does a write that fails or does not stick. lw_ver says
# which. The authentication and the login are never stored (R73f).
lw_profile_set() {
	local t=$1 rc=0
	lw_ver=1
	if [ "$lw_p_ok" = 1 ] && lw_p_is "$t"; then
		lw_dbg "profile 1 holds the APN and $t, no write"
		return 0
	fi
	# the record shows a change of the type before the first one of this start (R73n)
	if [ "$lw_marked" != 1 ] && [ "$lw_p0_ok" = 1 ] && [ "$t" != "$lw_p0_type" ]; then
		lw_marked=1
		lw_rec_put change "$lw_p0_type"
	fi
	lw_wrote=1
	lw_qa 1000 --modify-profile "3gpp,1" --apn "$apn" --pdp-type "$t" || rc=$?
	if [ "$rc" != 0 ]; then
		lw_ver=0
		lw_p_ok=0
		lw_dbg "profile write to $t failed (status $rc), unverified"
		return 0
	fi
	if [ "$lw_p_ok" != 1 ]; then
		lw_ver=0
		lw_dbg "profile 1 not readable, write to $t unverified"
		return 0
	fi
	if lw_profile_read && lw_p_is "$t"; then
		return 0
	fi
	lw_ver=0
	lw_dbg "profile write to $t did not stick, unverified"
}

# lw_reconcile CID: a start whose answer did not come: ask that client; a call that is up with a
# handle we never got is stopped on its client only when no call of this start is up beside it (no
# wildcard stop beside a sibling, R73e), else it is left for the next start's sweep (R73m)
lw_reconcile() {
	lw_q 1000 --set-client-id wds,"$1" --get-data-status
	if [ "$lw_out" = '"connected"' ]; then
		if [ -n "$pdh_4$pdh_6" ]; then
			lw_dbg "client $1 holds a call of unknown handle beside a working one, left for the next start"
			return 0
		fi
		lw_q 1000 --set-client-id wds,"$1" --stop-network 0xffffffff --autoconnect
	fi
	lw_release "$1"
}

# lw_call FAMILY: one call on a client of its own (R73e). 0: granted, cid_N and pdh_N are set; 1:
# refused or failed; 2: no client. A call counts only with a numeric handle and the status
# connected (R73a); one that failed after it started is stopped by its handle before its client is
# released.
lw_call() {
	local f=$1 cid pdh st rc=0 a_apn a_prof ac
	lw_qa 1000 --get-client-id wds
	cid=$lw_out
	if ! [ "$cid" -eq "$cid" ] 2>/dev/null; then
		lw_say "Unable to obtain client ID"
		lw_nocid=$((lw_nocid + 1))
		return 2
	fi
	lw_got=$((lw_got + 1))
	if ! lw_qa 1000 --set-client-id wds,"$cid" --set-ip-family "ipv$f"; then
		lw_say "Unable to set the IP family"
		lw_release "$cid"
		return 1
	fi
	case $f in
	4) a_apn=$apn a_prof=$profile ac=$lw_ac4 ;;
	6) a_apn=${v6apn:-$apn} a_prof=${v6profile:-$profile} ac=$lw_ac6 ;;
	esac
	lw_qa 5000 --set-client-id wds,"$cid" --start-network \
		${a_apn:+--apn $a_apn} \
		${a_prof:+--profile $a_prof} \
		${auth:+--auth-type $auth} \
		${username:+--username $username} \
		${password:+--password $password} \
		${ac:+--autoconnect} || rc=$?
	pdh=$lw_out
	if ! [ "$pdh" -eq "$pdh" ] 2>/dev/null; then
		lw_say "Unable to connect IPv$f"
		# no answer, or none in time (also uqmi's own -t, whose text says "timed out"): the call
		# may have reached the modem (R73e)
		case $pdh in '' | *'timed out'*) rc=124 ;; esac
		if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
			lw_reconcile "$cid"
		else
			lw_release "$cid"
		fi
		return 1
	fi
	if [ "$f" = 6 ]; then
		lw_qa 1000 --set-client-id wds,"$cid" --set-ip-family ipv6 --get-data-status || :
	else
		lw_qa 1000 --set-client-id wds,"$cid" --get-data-status || :
	fi
	st=$lw_out
	if [ "$st" != '"connected"' ]; then
		lw_say "No data link!"
		lw_q 1000 --set-client-id wds,"$cid" --stop-network "$pdh" || :
		lw_release "$cid"
		return 1
	fi
	case $f in
	4) cid_4=$cid pdh_4=$pdh ;;
	6) cid_6=$cid pdh_6=$pdh ;;
	esac
	return 0
}

# lw_more: no call is up yet, the steps may go on: no repeated failure to get a client (R73d) and
# time for another attempt (R73h)
lw_more() {
	[ -z "$pdh_4$pdh_6" ] || return 1
	[ "$lw_nocid" -lt 2 ] || return 1
	lw_left
	[ "$lw_s" -gt "$LW_RESERVE" ]
}

# lw_step TYPE FAMILIES: profile 1 for TYPE, then one call per family in turn, each on its own client
lw_step() {
	local t=$1 f r
	lw_profile_set "$t"
	for f in $2; do
		lw_left
		if [ "$lw_s" -le "$LW_RESERVE" ] || [ "$lw_nocid" -ge 2 ]; then
			lw_dbg "step $t stops before the IPv$f call: no time or no client left"
			break
		fi
		r=0
		lw_call "$f" || r=$?
		if [ "$r" = 0 ]; then
			lw_ok_type=$t
		elif [ "$lw_ver" = 1 ]; then
			lw_dbg "IPv$f refused in step $t ($lw_why)"
		else
			lw_dbg "IPv$f call failed in step $t after an unverified profile write, not counted as refused"
		fi
	done
}

# lw_rollback: after a start whose steps all failed, profile 1 gets back the type it had before the
# start, only when this start changed it; the APN of the start stays; the write is checked (R73n).
# What cannot be done in time is left to the next start, which writes the profile itself.
lw_rollback() {
	[ "$lw_wrote" = 1 ] && [ "$lw_p0_ok" = 1 ] || return 0
	case $lw_p0_type in ipv4 | ipv6 | ipv4v6) ;; *) return 0 ;; esac
	if lw_profile_read c && [ "$lw_p_type" = "$lw_p0_type" ]; then
		return 0
	fi
	if lw_q 1000 --modify-profile "3gpp,1" --apn "$apn" --pdp-type "$lw_p0_type" &&
		lw_profile_read c && [ "$lw_p_type" = "$lw_p0_type" ]; then
		lw_dbg "profile 1 is back at $lw_p0_type"
	else
		lw_dbg "profile 1 rollback to $lw_p0_type not confirmed, left for the next start"
	fi
}

# lw_negotiate: the call setup of this handler (R73 to R73o). Auto (pdptype ipv4v6) runs the steps
# IPV4V6 with an IPv4 and an IPv6 call, then IP with an IPv4 call, then IPV6 with an IPv6 call, and
# stops at the first step that gives a call; forced IPv4 and forced IPv6 run one step. The first
# survivor is kept at once, a refusal is no failure while a call is up (R73b), and the sequence
# ends in one failure only when every step failed (R73d). Only calls that started and read connected
# reach cid_N and pdh_N, which the caller publishes.
lw_negotiate() {
	local mode
	lw_now
	lw_dl=$((lw_t + LW_NEG_SECONDS))
	lw_debug='' lw_why='' lw_ok_type=''
	lw_nocid=0 lw_got=0 lw_wrote=0 lw_marked=0 lw_ver=1
	lw_p_ok=0 lw_p0_ok=0 lw_p0_type=
	mode=$(echo "$pdptype" | awk '{print tolower($0)}')
	case $mode in
	ipv4v6 | ipv6) ;;
	*) mode=ipv4 ;;
	esac
	lw_forced=1
	[ "$mode" != ipv4v6 ] || lw_forced=0
	# R73g: the IPv4 call has autoconnect unless the option is 0, the IPv6 call only when it is 1
	lw_ac4=1
	[ "$autoconnect" != 0 ] || lw_ac4=
	lw_ac6=
	[ "$autoconnect" != 1 ] || lw_ac6=1
	if lw_profile_read; then
		lw_p_ok=1 lw_p0_ok=1 lw_p0_type=$lw_p_type
	fi
	lw_dbg "negotiation starts, mode $mode, profile 1 $([ "$lw_p_ok" = 1 ] && echo readable || echo unreadable)"
	case $mode in
	ipv4v6)
		lw_step ipv4v6 "4 6"
		if lw_more; then lw_step ipv4 4; fi
		if lw_more; then lw_step ipv6 6; fi
		;;
	ipv6) lw_step ipv6 6 ;;
	*) lw_step ipv4 4 ;;
	esac
	if [ -n "$pdh_4$pdh_6" ]; then
		# the type this start came up with, also IPV4V6 on a SIM that gave only IPv4 (R73n)
		lw_rec_put ok "$lw_ok_type"
		return 0
	fi
	lw_rollback
	[ "$lw_forced" = 1 ] || [ -z "$lw_why" ] || echo "$lw_why"
	if [ "$lw_nocid" -gt 0 ] && [ "$lw_got" = 0 ]; then
		proto_notify_error "$interface" NO_CID
	else
		proto_notify_error "$interface" CALL_FAILED
	fi
	return 1
}

# lw_repair: before registration, profile 1 is put back once to the type of a recorded change that a
# cut-off start began, when the SIM and the APN are the same; a type that differs from the record
# is no reason alone, and a first start or a new SIM takes the normal path (R73n, D203)
lw_repair() {
	local sim
	lw_rec_read && [ "$lw_rk" = change ] || return 0
	[ "$lw_ra" = "${apn:--}" ] || return 0
	lw_now
	lw_dl=$((lw_t + 10))
	lw_sim
	sim=$lw_sim_id
	# an unknown SIM never matches, not even an unknown one in the record (D203)
	[ "$sim" != - ] && [ "$sim" = "$lw_rs" ] || return 0
	lw_profile_read c || return 0
	[ "$lw_p_type" != "$lw_rt" ] || return 0
	case $lw_rt in ipv4 | ipv6 | ipv4v6) ;; *) return 0 ;; esac
	lw_q 1000 --modify-profile "3gpp,1" --apn "$apn" --pdp-type "$lw_rt" || :
	lw_dbg "profile 1 put back to $lw_rt before registration"
}

# lw_v6_ok: the IPv6 settings the modem reports for the call are complete and valid (R73j); else the
# session takes them from the link
lw_v6_ok() {
	local j ip gw dns pl
	lw_now
	lw_dl=$((lw_t + 10))
	lw_q 1000 --set-client-id wds,"$cid_6" --get-current-settings || return 1
	j=$lw_out
	ip=$(jsonfilter -s "$j" -e '@.ipv6.ip' 2>/dev/null)
	gw=$(jsonfilter -s "$j" -e '@.ipv6.gateway' 2>/dev/null)
	dns=$(jsonfilter -s "$j" -e '@.ipv6.dns1' 2>/dev/null)
	pl=$(jsonfilter -s "$j" -e '@.ipv6["ip-prefix-length"]' 2>/dev/null)
	case $ip in *:*) ;; *) lw_dbg "IPv6 settings: no valid address, taken from the link"; return 1 ;; esac
	case $gw in *:*) ;; *) lw_dbg "IPv6 settings: no valid gateway, taken from the link"; return 1 ;; esac
	case $dns in *:*) ;; *) lw_dbg "IPv6 settings: no valid DNS, taken from the link"; return 1 ;; esac
	case $pl in '' | *[!0-9]*) lw_dbg "IPv6 settings: no valid prefix length, taken from the link"; return 1 ;; esac
	[ "$pl" -ge 1 ] && [ "$pl" -le 128 ]
}

