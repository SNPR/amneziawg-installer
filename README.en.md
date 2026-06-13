<a id="top"></a>
<p align="center">
  <b>RU</b> <a href="README.md">Русский</a> | <b>EN</b> English
</p>

<p align="center">
  <img src="logo.jpg" alt="AmneziaWG 2.0 VPN installer" width="600">
</p>

<h1 align="center">AmneziaWG 2.0 — installer with server cascade and WARP</h1>

<p align="center"><em>One-command VPN on Ubuntu 24.04 / 25.10 / 26.04 and Debian 12 / 13. Kernel-native via DKMS, no Docker, no web panel.</em></p>

<p align="center">
  <img src="https://img.shields.io/badge/Ubuntu-24.04_|_25.10_|_26.04-orange" alt="Ubuntu">
  <img src="https://img.shields.io/badge/Debian-12_|_13-A81D33" alt="Debian">
  <img src="https://img.shields.io/badge/Arch-x86__64_|_ARM64_|_ARMv7-green" alt="Arch">
  <img src="https://img.shields.io/badge/AmneziaWG-2.0-blueviolet" alt="AWG 2.0">
  <img src="https://img.shields.io/badge/Installer_Version-5.15.6-blue" alt="Installer version">
  <img src="https://img.shields.io/badge/upstream-bivlked_5.15.6-blue" alt="Upstream baseline">
</p>

---

This is a fork of [**bivlked/amneziawg-installer**](https://github.com/bivlked/amneziawg-installer) — a Bash installer for an AmneziaWG 2.0 VPN server. The fork carries **every upstream change up to 5.15.6** (DKMS self-repair, dual-stack IPv6, hardened validators, fail2ban fixes, etc.) plus its own features that upstream does not have.

<a id="diff"></a>
## What this fork adds over upstream

| Feature | Flag | Why |
|---|---|---|
| **Two-node cascade (multi-hop)** | `--role=entry` / `--role=exit` + `--upstream-conf=` | Traffic enters on one VPS and exits to the internet through another |
| **Cloudflare WARP egress** | `--egress=warp` | Sites see a Cloudflare IP instead of your VPS IP |
| **WARP exceptions** | `--warp-bypass=youtube,custom:...` | Selected destinations skip WARP (e.g. YouTube goes direct) |
| **AmneziaDNS — per-site split** | `--amnezia-dns=on` | Local dnsmasq on the tunnel gateway + "native" Amnezia import; unlocks the site-split UI in the app |
| **Privileged ports** | `--port=443` (also 53, 500) | Defeats mobile-carrier DPI; upstream rejected ports below 1024 |
| **Fake QUIC in I1** | `--i1-mode=quic` | Disguises the first packet as a QUIC Initial for DPI bypass |
| **Install from a clone** | — | Running from `git clone` uses the local scripts, no CDN download — guarantees the fork's changes land on the node |

A full walkthrough of the cascade and WARP lives in [**MULTIHOP.en.md**](MULTIHOP.en.md).

<a id="install"></a>
## Install (single server)

Clone the fork to a path that is **not** `/root/awg` (the installer's working directory):

```bash
git clone https://github.com/SNPR/amneziawg-installer.git /root/amneziawg-installer
cd /root/amneziawg-installer
sudo bash install_amneziawg_en.sh --yes
```

If the installer asks for a reboot (usually 1–2 times), accept it; after the reboot run the **same command** again and the script resumes from where it stopped.

Ready-made client configs appear in `/root/awg/` (`my_phone.conf` + `my_phone.png` QR, `my_laptop.conf` + QR). Import them into the Amnezia VPN app or any WireGuard-compatible client.

Handy single-server options:

```bash
--port=443             # privileged port against DPI
--amnezia-dns=on       # per-site split tunneling via the Amnezia app
--egress=warp          # exit to the internet through Cloudflare WARP
--i1-mode=quic         # disguise I1 as QUIC
```

<a id="cascade"></a>
## Two-server cascade (multi-hop)

```
phone/laptop  →  Node 2 (entry)  →  Node 1 (exit)  →  internet
                 clients connect     traffic exits
                 here                here
```

The two nodes must use different subnets — set them with `--subnet=` (exit → `10.9.0.1/24`, entry → `10.8.0.1/24`). Clone the fork on **both** nodes (as in the install section).

### 1. Exit node — `198.51.100.20` in the example

```bash
# install
sudo bash install_amneziawg_en.sh --role=exit --subnet=10.9.0.1/24 --yes

# a "client" config the entry node will use to reach the exit node
sudo bash /root/awg/manage_amneziawg.sh add hop_to_entry

# hand it to the entry node
scp /root/awg/hop_to_entry.conf root@203.0.113.10:/root/
```

Nothing else to configure on the exit node. (You may even install it with the original upstream script — the exit node needs no cascade specifics; `--role=exit` only tags the node in its config.)

### 2. Entry node — `203.0.113.10` in the example

This node **needs this fork** — only it has `--role=entry` / `--upstream-conf=`, which bring up the second `awg1` interface and the policy-routing to the exit node.

```bash
# /root/hop_to_entry.conf is already on the node (from the scp above)
sudo bash install_amneziawg_en.sh \
  --role=entry \
  --upstream-conf=/root/hop_to_entry.conf \
  --subnet=10.8.0.1/24 \
  --yes
```

The installer brings up `awg0` (the client-facing server), `awg1` (the hidden tunnel to the exit node) and writes policy-routing + MASQUERADE + TCPMSS clamp. The client configs in `/root/awg/` point their **Endpoint at the entry node**, which is correct.

### Verify

```bash
sudo bash /root/awg/manage_amneziawg.sh upstream show   # handshake with the exit node
# connect a client, then on the device:
curl ifconfig.me                                        # should return the exit node's IP
```

The full routing breakdown, diagnostics and tuning are in [MULTIHOP.en.md](MULTIHOP.en.md).

<a id="warp"></a>
## Cloudflare WARP egress (optional)

Installs **only on the exit node or a single server** (rejected on entry). The installer downloads [wgcf](https://github.com/ViRb3/wgcf), registers a free WARP account, brings up `wg-quick@wgcf` and routes client traffic into WARP while keeping the node's own SSH/apt/handshake on the main interface.

```bash
sudo bash install_amneziawg_en.sh --role=exit --subnet=10.9.0.1/24 --egress=warp --yes   # in a cascade
sudo bash install_amneziawg_en.sh --egress=warp --yes                                    # single server
```

Exclude some traffic from WARP (e.g. YouTube — direct from the exit node's IP):

```bash
--warp-bypass=youtube
--warp-bypass=youtube,custom:https://example.com,custom:/etc/awg/extra-domains.txt
```

Details, verification and gotchas (free-tier speed, blocked Cloudflare IPs, MTU) are in the WARP section of [MULTIHOP.en.md](MULTIHOP.en.md).

<a id="manage"></a>
## Management

```bash
sudo bash /root/awg/manage_amneziawg.sh add <name>       # add a client
sudo bash /root/awg/manage_amneziawg.sh remove <name>    # remove
sudo bash /root/awg/manage_amneziawg.sh list [--json]    # list
sudo bash /root/awg/manage_amneziawg.sh regen [name]     # regenerate configs
sudo bash /root/awg/manage_amneziawg.sh restart          # restart tunnels
sudo bash /root/awg/manage_amneziawg.sh upstream show    # cascade status (on the entry node)
sudo bash /root/awg/manage_amneziawg.sh diagnose         # self-diagnostics
sudo bash /root/awg/manage_amneziawg.sh repair-module    # rebuild the module after a kernel upgrade
```

<a id="docs"></a>
## Documentation

- [MULTIHOP.en.md](MULTIHOP.en.md) — two-node cascade and WARP egress, step by step.
- [ADVANCED.en.md](ADVANCED.en.md) — every CLI flag, manual install, carrier-specific DPI bypass.
- [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer) — the original project this fork is based on.

## Requirements

OS support: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / Debian 13. Architectures x86_64 / ARM64 / ARMv7, ≥ 1 GB RAM, root access. A cascade needs two such VPS.

## License

MIT, same as upstream. Based on [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer) — thanks to the author for the base project.
