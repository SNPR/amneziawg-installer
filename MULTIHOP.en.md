<p align="center">
  <b>RU</b> <a href="MULTIHOP.md">Русский</a> | <b>EN</b> English
</p>

# Multi-hop (cascade) of two AmneziaWG servers

A plain-language guide: how to chain two VPSes so that client traffic enters one node but exits to the internet via the other.

---

## Who is who

You have two servers:

- **Node 1 (exit)** — the one you want to use for internet egress (usually foreign). Example IP: `198.51.100.20`.
- **Node 2 (entry)** — the one your phone/laptop connect to. Example IP: `203.0.113.10`.

How the traffic flows: **phone → Node 2 → Node 1 → internet**.

---

## One important tip before you start

Both nodes default to the same subnet `10.9.9.0/24`. It will work, but debugging is painful. Pick different ones via `--subnet=`:

- Node 1 (exit)  → `10.9.0.1/24`
- Node 2 (entry) → `10.8.0.1/24`

---

## First — clone the fork on both nodes

**Important:** clone the fork into a path that is **NOT** `/root/awg` (that's the installer's working directory). Standard layout:

```bash
git clone https://github.com/SNPR/amneziawg-installer.git /root/amneziawg-installer
cd /root/amneziawg-installer
```

In step 5 the installer detects that `awg_common.sh` and `manage_amneziawg.sh` live next to it and uses those directly — **no upstream CDN download**. Our `--role=entry` and `--egress=warp` changes are guaranteed to land on the target node.

## Node 1 (exit) — the "egress" server

On the exit node you can use **the original upstream script** ([bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer)) without our modifications — a plain AmneziaWG 2.0 server is all it needs, nothing cascade-specific. If you prefer consistency, run our fork with `--role=exit` — the resulting config will be identical (the `--role=exit` flag just stamps the role into `awgsetup_cfg.init` for bookkeeping).

**Step A.** Install (single command from the clone directory):

```bash
sudo bash install_amneziawg_en.sh \
  --role=exit \
  --subnet=10.9.0.1/24 \
  --yes
```

If it asks for a reboot (usually 1–2 times) — accept, then re-run **the same command** after reboot, the script resumes from where it stopped.

**Step B.** Create a "client" config that node 2 will use to attach to node 1:

```bash
sudo bash /root/awg/manage_amneziawg.sh add hop_to_entry
```

This produces `/root/awg/hop_to_entry.conf`.

**Step C.** Copy that file to node 2:

```bash
scp /root/awg/hop_to_entry.conf root@203.0.113.10:/root/
```

**That's it. Nothing else to do on node 1.**

---

## Node 2 (entry) — the client-facing server

On the entry node you **need our fork** — only it has the `--role=entry` and `--upstream-conf=` flags that bring up the second `awg1` interface and set up the policy routing.

Make sure `/root/hop_to_entry.conf` is on node 2 (from the `scp` above). Then, a single command:

```bash
sudo bash install_amneziawg_en.sh \
  --role=entry \
  --upstream-conf=/root/hop_to_entry.conf \
  --subnet=10.8.0.1/24 \
  --yes
```

Same story with reboots: accept and re-run the same command.

At the end the script itself:

- brings up `awg0` — the server for your clients
- brings up `awg1` — the hidden tunnel to node 1
- installs policy routing, MASQUERADE and TCPMSS clamp (so HTTPS sites don't break)

---

## How to pick up clients

Node 2 already has ready-to-use client configs:

- `/root/awg/my_phone.conf` + `my_phone.png` (QR)
- `/root/awg/my_laptop.conf` + `my_laptop.png`

Download them and import into the Amnezia VPN client ≥ 4.8.12.7. **The `Endpoint` in those configs is node 2's IP** (not node 1's), which is correct.

To add another client:

```bash
sudo bash /root/awg/manage_amneziawg.sh add vasya
```

---

## How to verify the cascade is alive

On node 2:

```bash
sudo bash /root/awg/manage_amneziawg.sh upstream show
# Should show a handshake with node 1 (recent, seconds/minutes)

awg show
# Two sections: awg0 (your clients) and awg1 (node 1 as a peer)
```

Connect with a client and on that device:

```bash
curl ifconfig.me
```

If it returned **node 1's IP** (`198.51.100.20` in the example) rather than node 2's — the cascade is live, everything works.

---

## Everyday commands on node 2

```bash
sudo bash /root/awg/manage_amneziawg.sh add <name>        # add a client
sudo bash /root/awg/manage_amneziawg.sh remove <name>     # remove one
sudo bash /root/awg/manage_amneziawg.sh list              # list clients
sudo bash /root/awg/manage_amneziawg.sh restart           # restart both tunnels
sudo bash /root/awg/manage_amneziawg.sh upstream restart  # just the cascade
sudo bash /root/awg/manage_amneziawg.sh upstream show     # cascade status
```

---

## Troubleshooting

1. **No handshake on `awg1` (node 2 cannot see node 1)** → on node 1 check `ufw status` — there must be `ALLOW 39743/udp` (or your port).
2. **Handshake is there, but the client can't reach the internet** → on node 2 look at `iptables -L FORWARD -n -v` — you need ACCEPT rules for `awg0 → awg1` and the reverse.
3. **`curl ifconfig.me` shows node 2's IP, not node 1's** → on node 2 check `ip rule` — there must be a `from 10.8.0.0/24 lookup 123` line.
4. **Want to start over** → `sudo bash install_amneziawg_en.sh --uninstall` on both nodes.

---

## How it works under the hood (short version)

- The entry node's `awg0.conf` does not `MASQUERADE` on `eth0`; it only `FORWARD`s between `%i` and `awg1` and clamps SYN TCPMSS.
- `awg1.conf` gets `Table=123` and `FwMark=0xca6d`, plus a `PostUp`: `ip rule add from 10.8.0.0/24 table 123 priority 456` and `MASQUERADE -o %i`.
- A client packet: **src=10.8.0.5** → lands on `awg0` → `FORWARD → awg1` → `ip rule` matches by src → table 123 → default via `awg1` → `MASQUERADE` (src becomes `10.9.0.2` — entry's address on the exit side) → encryption → exit over UDP → decrypted on the exit node → `MASQUERADE` on its `eth0` → internet.
- The return packet arrives on the exit (dst=exit public IP), gets DNAT'ed back through conntrack to `10.9.0.2` (entry), is encrypted in the exit's `awg0`, reaches the entry's `awg1`, conntrack restores dst=`10.8.0.5`, `FORWARD → awg0` → back to the client.

The parameters that **must match between `awg1` (entry) and `awg0` (exit)** for the cascade to live: `Jc / Jmin / Jmax / S1-S4 / H1-H4`. The script reads them from `hop_to_entry.conf`, which was produced on the exit node — so the match is guaranteed.

---

## Option: route exit-node traffic through Cloudflare WARP

If you want external sites to see a **Cloudflare IP** instead of your exit VPS IP, you can add a third hop — Cloudflare WARP. Useful when the exit node's IP already landed on some blocklist, or just to mask the VPS provider.

Enabled **only on the exit node** (or on a single-server without cascade). On the entry node the `--egress=warp` flag is rejected — WARP there would be a pointless third wrapper.

### How to enable

Add `--egress=warp` to the exit-node install:

```bash
sudo bash install_amneziawg_en.sh \
  --role=exit \
  --subnet=10.9.0.1/24 \
  --egress=warp \
  --yes
```

Or for a single (non-cascade) server:

```bash
sudo bash install_amneziawg_en.sh --egress=warp --yes
```

The script will automatically:

1. Download [wgcf](https://github.com/ViRb3/wgcf) (the Cloudflare WARP WireGuard client).
2. Register a free WARP account via `wgcf register --accept-tos`.
3. Generate `/etc/wireguard/wgcf.conf` and patch it: `Table = off` (otherwise the host default route moves into WARP and SSH drops), strip the `DNS =` line.
4. Enable `wg-quick@wgcf`.
5. Append to `awg0.conf` PostUp: `ip rule from <subnet> table 2408`, `ip route default dev wgcf table 2408`, `MASQUERADE -o wgcf`, TCPMSS clamp — so the client traffic egresses via `wgcf` while the node's own traffic (SSH, apt, handshakes from entry) keeps using `eth0`.

### Verification

On the exit node:

```bash
# Interface is up and the Cloudflare handshake is recent:
sudo wg show wgcf

# Policy-routing is in place:
ip rule | grep 2408
ip route show table 2408
```

From a client (after connecting to the VPN):

```bash
curl ifconfig.me
```

Should return an **IP from the Cloudflare range** (`104.x` / `162.x`), not the exit-node IP.

### Caveats

- **Free WARP throttles** at peak hours. 20–50 Mbps drops are normal for the free tier.
- **Cloudflare IPs can be blocked** by some sites (banks, streaming). If something stopped working after enabling — it's not the cascade, it's blocklists.
- **Triple encapsulation** (client→entry→exit→WARP) eats into MTU. Without the TCPMSS clamp (which the script already adds) some HTTPS sites would hang on handshake.
- **`100.64.0.0/10`** is WARP's internal subnet. Don't use it as `--subnet=` for AWG clients.

### Fine-tuning

```bash
--warp-table=N       # routing table (default 2408)
--warp-priority=N    # ip rule priority (default 789)
```

A collision with `--upstream-table` (123) is checked during validation.

### Removal

Changed your mind? Just run `sudo bash install_amneziawg_en.sh --uninstall`. The script carefully tears down `wg-quick@wgcf`, `wgcf.conf`, the account file and the `wgcf` binary itself — but only if WARP was raised by our installer (marker `.wgcf_enabled_by_installer`). If wgcf existed before our install, uninstall leaves it alone.
