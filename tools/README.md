# macOS network diagnostics

`netdiag.sh` runs the three commands worth reaching for when Wi-Fi misbehaves,
and derives the one number none of them print on its own: **SNR**.

```sh
chmod +x tools/netdiag.sh
./tools/netdiag.sh            # full output, prompts for sudo
./tools/netdiag.sh -n         # skip sudo; radio metrics only
./tools/netdiag.sh -r         # mask MAC/SSID/BSSID before sharing
```

## The commands

### `sudo wdutil info`

The current source of radio-layer truth: channel, RSSI, noise, PHY mode, Tx
rate, security, MCS index.

`sudo` is not optional for the *identifiers*. Run it unprivileged and macOS
prints `<redacted>` for MAC address, SSID, and BSSID — the radio metrics
(RSSI, noise, channel, PHY mode) still come through, which is usually all you
need for a signal complaint.

This replaced the old `airport` utility, which started warning on deprecation
in macOS 14 and was removed in 14.4. If you have a script still calling
`/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport`,
that is why it broke.

Fields worth reading:

| Field | What it tells you |
|---|---|
| `Channel` | e.g. `5g149/80` — band, channel number, width in MHz. A 20 MHz width on 5 GHz means something negotiated you down. |
| `RSSI` | Received signal strength, dBm. Closer to 0 is stronger. |
| `Noise` | Noise floor, dBm. Typically around -90; anything above -80 means a congested or interfered band. |
| `PHY Mode` | `11ac`, `11ax`, … — if you are on Wi-Fi 6 hardware and see `11n`, you are not associated the way you think. |
| `Tx Rate` | Negotiated rate, Mbps. This is the link rate, not your throughput. |
| `MCS Index` | Modulation/coding tier. Drops as SNR degrades. |

### `networksetup -getinfo "Wi-Fi"`

The service layer: IP address, subnet mask, router, and the interface MAC
(reported as `Wi-Fi ID`), plus whether the address came from DHCP or was set
manually.

Two gotchas:

- It takes a **service** name, not a device name. The service is usually
  called `Wi-Fi`, but it can be renamed — in which case the literal command
  fails. `netdiag.sh` resolves the real name via
  `networksetup -listallhardwareports` → device → `-listnetworkserviceorder`
  rather than hardcoding the string.
- It does **not** report DNS. For that:
  ```sh
  networksetup -getdnsservers "Wi-Fi"   # statically configured servers
  scutil --dns | grep nameserver        # what is actually in effect, incl. DHCP
  ```
  `-getdnsservers` prints "There aren't any DNS Servers set" when DNS comes
  from DHCP, which is not the same as having no DNS.

### `arp -a`

The neighbour layer: IP-to-MAC mappings the machine has cached.

This is a **cache, not a scan**. It only lists hosts this Mac has recently
exchanged traffic with, so an empty or short list is normal. Ping the router
or sweep the subnet first if you want a fuller picture. Entries are tagged
with the interface (`on en0`) and your own interface shows as `permanent`.

## Reading the result

The script computes **SNR = RSSI − noise** and grades it, because SNR predicts
throughput better than RSSI does. A strong signal in a noisy band performs
worse than a moderate signal in a quiet one — which is the case that pure
signal-bar diagnostics consistently get wrong.

| SNR | Reading |
|---|---|
| ≥ 40 dB | Excellent — top rates available |
| 25–40 dB | Good — reliable for video and calls |
| 15–25 dB | Fair — rate adaptation will back off |
| 10–15 dB | Marginal — retransmits likely |
| < 10 dB | Poor — the link struggles regardless of RSSI |

So: RSSI of -55 with a -92 noise floor gives 37 dB and is healthy, while the
same -55 against a -70 noise floor gives 15 dB and will feel slow despite the
identical signal strength.

## Notes

- macOS only. The script exits early on anything else; `wdutil` and
  `networksetup` do not exist elsewhere.
- Targets the stock macOS shell (bash 3.2), so it avoids bash 4+ syntax.
- `-r` keeps the OUI (first three octets) of each MAC so you can still tell
  vendors apart, and drops the host portion.
