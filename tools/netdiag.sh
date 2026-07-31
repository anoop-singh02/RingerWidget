#!/usr/bin/env bash
#
# netdiag.sh - macOS Wi-Fi / local network diagnostics
#
# Wraps the three commands worth running when a Wi-Fi link misbehaves:
#
#   wdutil info                 channel, RSSI, noise, PHY mode  (needs sudo)
#   networksetup -getinfo Wi-Fi IP, subnet, router, MAC (no DNS -- see README)
#   arp -a                      who else is on the L2 segment
#
# On top of the raw output it derives SNR (RSSI - noise), which is the number
# that actually predicts throughput -- a strong signal sitting in a noisy band
# performs worse than a weaker signal in a quiet one.
#
# Written for the stock macOS shell (bash 3.2), so no bash 4+ constructs.

set -uo pipefail

REDACT=0
USE_SUDO=1

usage() {
	cat <<'EOF'
Usage: netdiag.sh [-r] [-n] [-h]

  -r, --redact    Mask MAC addresses, SSID and BSSID in the output. Use this
                  before pasting results into a ticket or a chat.
  -n, --no-sudo   Skip the sudo escalation for `wdutil info`. Radio metrics
                  (channel/RSSI/noise/PHY) still print; macOS redacts the
                  identifiers (MAC/SSID/BSSID) on your behalf.
  -h, --help      Show this help.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-r|--redact)  REDACT=1 ;;
		-n|--no-sudo) USE_SUDO=0 ;;
		-h|--help)    usage; exit 0 ;;
		*) echo "netdiag.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

if [ "$(uname -s)" != "Darwin" ]; then
	echo "netdiag.sh: macOS only -- wdutil and networksetup do not exist on $(uname -s)." >&2
	exit 1
fi

heading() {
	printf '\n\033[1m%s\033[0m\n' "$1"
	printf '%s\n' "------------------------------------------------------------"
}

note() { printf '  \033[2m%s\033[0m\n' "$1"; }

# Mask identifiers when -r is set. MACs keep their OUI (first three octets) so
# you can still tell vendors apart; the host portion is dropped.
redact() {
	if [ "$REDACT" -eq 1 ]; then
		sed -E \
			-e 's/([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}):[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}/\1:xx:xx:xx/g' \
			-e 's/^([[:space:]]*(SSID|BSSID)[[:space:]]*:[[:space:]]*).*$/\1<redacted>/'
	else
		cat
	fi
}

# The Wi-Fi service is usually called "Wi-Fi", but it can be renamed, and
# `networksetup -getinfo` takes the *service* name rather than the device.
# Resolve it via the hardware port -> device -> service chain instead of
# hardcoding the string.
wifi_device() {
	networksetup -listallhardwareports 2>/dev/null \
		| awk '/^Hardware Port: Wi-Fi$/ { getline; if ($1 == "Device:") print $2; exit }'
}

wifi_service() {
	networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="$1" '
		/^\([0-9*]+\)/ { svc = substr($0, index($0, ")") + 2); next }
		/Device: / {
			d = $0
			sub(/.*Device: /, "", d)
			sub(/\).*/, "", d)
			if (d == dev && svc != "") { print svc; exit }
		}'
}

# Read a "Key : Value" field out of wdutil's output and keep only the number,
# e.g. "    RSSI                 : -55 dBm" -> "-55".
wdutil_number() {
	printf '%s\n' "$2" | awk -F: -v key="$1" '
		$0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
			gsub(/[^-0-9]/, "", $2)
			if ($2 != "") { print $2; exit }
		}'
}

rssi_verdict() {
	if   [ "$1" -ge -50 ]; then echo "excellent"
	elif [ "$1" -ge -60 ]; then echo "good"
	elif [ "$1" -ge -70 ]; then echo "fair -- expect reduced throughput"
	elif [ "$1" -ge -80 ]; then echo "weak -- move closer or change band"
	else                        echo "very poor -- at the edge of usable"
	fi
}

snr_verdict() {
	if   [ "$1" -ge 40 ]; then echo "excellent -- top rates available"
	elif [ "$1" -ge 25 ]; then echo "good -- reliable for video/calls"
	elif [ "$1" -ge 15 ]; then echo "fair -- rate adaptation will back off"
	elif [ "$1" -ge 10 ]; then echo "marginal -- retransmits likely"
	else                       echo "poor -- link will struggle regardless of RSSI"
	fi
}

# ---------------------------------------------------------------- radio layer

heading "RADIO  (wdutil info)"

wd=""
if [ "$USE_SUDO" -eq 1 ]; then
	if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
		note "sudo will prompt for your password (needed to unredact identifiers)."
	fi
	wd="$(sudo wdutil info 2>&1)"
else
	wd="$(wdutil info 2>&1)"
	note "Running without sudo -- macOS redacts MAC/SSID/BSSID below."
fi

if [ -z "$wd" ]; then
	note "wdutil returned nothing (is Wi-Fi powered on?)."
else
	printf '%s\n' "$wd" | redact
fi

rssi="$(wdutil_number RSSI "$wd")"
noise="$(wdutil_number Noise "$wd")"

if [ -n "$rssi" ] || [ -n "$noise" ]; then
	heading "SIGNAL QUALITY  (derived)"
	[ -n "$rssi" ]  && printf '  %-18s %s dBm  (%s)\n' "RSSI"  "$rssi"  "$(rssi_verdict "$rssi")"
	[ -n "$noise" ] && printf '  %-18s %s dBm\n'        "Noise" "$noise"
	if [ -n "$rssi" ] && [ -n "$noise" ]; then
		snr=$((rssi - noise))
		printf '  %-18s %s dB   (%s)\n' "SNR" "$snr" "$(snr_verdict "$snr")"
		note "SNR = RSSI - noise. It predicts throughput better than RSSI alone."
	fi
fi

# ------------------------------------------------------------- service layer

dev="$(wifi_device)"
svc=""
[ -n "$dev" ] && svc="$(wifi_service "$dev")"
[ -z "$svc" ] && svc="Wi-Fi"

heading "SERVICE  (networksetup -getinfo \"$svc\")"
[ -n "$dev" ] && note "Wi-Fi service \"$svc\" is bound to device $dev."
networksetup -getinfo "$svc" 2>&1 | redact

# ----------------------------------------------------------- neighbour layer

heading "NEIGHBOURS  (arp -a)"

arp_out="$(arp -a 2>/dev/null)"
if [ -z "$arp_out" ]; then
	note "ARP cache is empty. Send some traffic first, e.g. ping your router."
else
	printf '%s\n' "$arp_out" | redact
	total="$(printf '%s\n' "$arp_out" | grep -c .)"
	printf '\n'
	note "$total ARP entries cached across all interfaces."
	if [ -n "$dev" ]; then
		on_wifi="$(printf '%s\n' "$arp_out" | grep -c " on ${dev} ")"
		note "$on_wifi of them reachable on $dev (the Wi-Fi segment)."
	fi
	note "The cache only lists hosts recently talked to -- it is not a full scan."
fi

printf '\n'
