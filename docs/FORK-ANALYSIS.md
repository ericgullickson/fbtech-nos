# Forking VyOS onto upstream Debian repositories

Analysis date: 2026-09-02. Based on `vyos/vyos-build` and `vyos/vyos-1x` at the `rolling`
branch heads of that day, Debian archive state from `qa.debian.org/madison`, and the Debian
trixie `linux-config-6.12` package.

## 1. Where VyOS stands today

| Fact | Value |
|---|---|
| Rolling base | Debian 12 bookworm (`data/defaults.toml`) |
| Rolling kernel | 6.18.48, self-built, 5 kernel patches, 27 config fragments |
| Trixie migration | Task T7557 open since 2025-06, PR vyos-build#978 closed, still "in progress" 2026-07 |
| LTS 1.5 (circinus) source | Public only as frozen `circinus-public-unmaintained` branch (bookworm, kernel 6.6.54, vyos-build last touched 2024-10) |
| Package build CI | `vyos-build-packages` is private. Only the ISO assembly repo is public. |
| Prebuilt packages | `packages.vyos.net/repositories/rolling` is public; LTS repos are subscriber-only |

Consequence: the only maintainable fork base is `rolling`. You must recreate the package
build pipeline and apt repository yourself.

## 2. What VyOS builds itself (43 groups in `scripts/package-build/`)

### A. VyOS-native, no Debian equivalent. Must be built forever (about 18 repos)

vyos-1x, vyatta-cfg (C++), vyatta-bash, vyatta-biosdevname, vyos1x-config / libvyosconfig
(OCaml), vyos-utils (OCaml), vyos-http-api-tools, hvinfo (Ada), ipaddrcheck, libnss-mapuser,
libpam-radius-auth (fork), libpam-tacplus + libnss-tacplus + libtacplus-map, vyos-cloud-init
(cloud-init fork with 5 `cc_vyos*` modules), live-boot (fork of a 2015 snapshot), vyos-live-build
(fork of a 2021 snapshot), shim-signed / efi-boot-shim, vyos-vpp-patches.

### B. Upstream software not in Debian at all. Must be built (or dropped)

accel-ppp-ng (PPPoE/L2TP/SSTP/IPoE server + kernel modules), telegraf, VPP + DPDK plugins,
zerotier-one, hsflowd, owamp/twamp, frr_exporter, nat-rtsp (kernel module), udp-broadcast-relay,
openvpn-otp, amazon-ssm-agent, amazon-cloudwatch-agent, aws-gwlbtun, xen-guest-agent,
unionfs-fuse (removed from Debian after bookworm; vyatta-cfg hard-depends on it), python3-vici,
Intel out-of-tree NIC drivers (igb/ixgbe/ixgbevf/i40e/ice/iavf), Intel QAT, Realtek r8126/r8152,
Mellanox OFED.

### C. Rebuilt from Debian sources only to get a newer version (no VyOS patches)

These become plain `apt install` on trixie. Version comparison:

| Package | VyOS builds | trixie | trixie-backports | forky/sid | vyos-1x requires |
|---|---|---|---|---|---|
| iproute2 | 6.18.0 | 6.15.0 | | 7.1.0 | >= 6.0 ok |
| ethtool | 6.10 | 6.14.2 | | 7.1 | >= 6.10 ok |
| keepalived | 2.3.3 | 2.3.3 | | 2.3.4 | ok |
| kea | 3.0.3 | 2.6.3 | 3.0.3 | 3.0.4 | pkg names differ (`isc-kea-*` vs `kea-dhcp4-server`) |
| podman | 5.8.4 | 5.4.2 | | 5.8.6 | >= 5.8 **fails on trixie** |
| netavark / aardvark-dns | 1.14.0 | 1.14.0 | | 1.17 | >= 1.14 ok |
| squid | 7.6 | 6.13 | | 7.6 | ok |
| ddclient | 3.11.x | 3.11.2 | | | >= 3.11.1 ok |
| hostapd / wpa | 2.10 + git | 2.10-24 | | | ok |
| radvd | 2.20 | 2.20 | | | >= 2.20 ok |
| bash-completion | **2.8 (pinned old)** | 2.16 | | | CLI breaks on newer, see 4 |
| blackbox / node exporter | 0.26 / 1.9.1 | 0.26 / 1.9.0 | | | pkg names differ (`prometheus-*`) |
| waagent | 2.9.1 | 2.12 | | | ok |
| dropbear | 2022.83 +PAM patch | 2025.89 | | | Debian build has no PAM |
| openssl | 3.0.20 +FIPS patch | 3.5.6 | | | FIPS module not built by Debian |
| net-snmp | 5.9.4 +2 patches | 5.9.4 | | | patches are bug fixes |
| nftables | 1.0.9 +1 fix | 1.1.3 | | | fix likely upstream |
| ndppd | 0.2.5 +2 patches | 0.2.5 | | | one patch is a real fix |

### D. Debian sources plus VyOS feature patches. These are the real compromises

| Package | VyOS version | Patches | What you lose on stock Debian |
|---|---|---|---|
| frr | 10.6.1 | 12, incl. **BGP-LS (18,944 lines)** | BGP link-state CLI, openfabric bits, pathd/SRv6 `no` command fixes, EVPN MACVLAN anycast, ospf6d LSA fixes, zebra last-address route removal. trixie ships 10.3 (>= 10.2 requirement met). |
| strongswan | 6.0.7 | 5: vici `initiate` source/remote override, vici cert + per-SA events, plugin trim, ML-KEM enable | **DMVPN** (NHRP-triggered tunnels) depends on the patched vici initiate. trixie has 6.0.1, vyos-1x requires >= 6.0.6. Whether Debian builds the `ml` plugin is unverified. |
| linux | 6.18 | `link_filter` sysctl (Vyatta legacy), perf pkg, bnx2x 2.5G, L2TP defer-route, arm64 build fix | `set interfaces ... disable-link-detect` writes `/proc/sys/net/ipv4/conf/X/link_filter`, which does not exist on a stock kernel. L2TPv3 tunnel creation without a route fails. |
| wide-dhcpv6 | 20080615 | per-interface DUID, single-socket bind, `no-release` (T5387) | `dhcpv6-options duid` and `no-release` silently stop working. VyOS itself is trying to move to dhcpcd (PR #1168, closed). |
| isc-dhcp | 4.4.3 | raw-IP / ARPHRD_NONE interface support | DHCP over WWAN (QMI raw-ip modems) breaks. isc-dhcp is EOL upstream anyway. |
| openssl | 3.0 | Enable FIPS module | `set system option fips` unusable. |
| dropbear | 2022.83 | Enable PAM | console-server auth against VyOS users breaks. |

## 3. Kernel: Debian stock kernel vs VyOS fragments

VyOS's 27 fragments request 796 `=y`/`=m` options. Against Debian trixie 6.12 amd64:

| Result | Count |
|---|---|
| Present with same or module state | 742 |
| VyOS `=y`, Debian `=m` (works, just modules) | 34 |
| Missing entirely | 20 |

The 20 missing: `MODULE_SIG_FORCE/ALL/SHA512` (VyOS signs its own modules for Secure Boot),
`INET_ESPINTCP`/`XFRM_ESPINTCP` (IPsec over TCP, RFC 8229), `OVPN` (OpenVPN DCO; the in-kernel
`ovpn` module only landed in 6.16, so trixie-backports 7.1 has it), `NETFILTER_XTABLES_COMPAT`,
squashfs decompressor tuning, obsolete ciphers (arc4, tea, seed, khazad, anubis, 842),
`CFG80211_CERTIFICATION_ONUS`, `WWAN_HWSIM`.

Out-of-tree modules on a Debian kernel:

| VyOS module | Debian option |
|---|---|
| ipt-netflow | `iptables-netflow-dkms` 2.6 in trixie |
| jool | `jool-dkms` 4.1.13 in trixie |
| accel-ppp kernel modules | none, DKMS package yourself |
| nat-rtsp | none, DKMS package yourself |
| Intel OOT igb/ixgbe/i40e/ice/iavf | use in-tree drivers, lose ixgbe unsupported-SFP override and 1000BASE-BX |
| Intel QAT OOT | in-tree `qat_4xxx` etc. exists, feature parity varies |
| Realtek r8126/r8152 | in-tree `r8169`/`r8152`, newer chips may lag |
| Mellanox OFED | in-tree mlx5 |

Recommendation: use `linux-image-amd64` from trixie-backports (7.1) rather than trixie (6.12)
to get `ovpn`, newer NIC drivers, and stay closer to VyOS's 6.18 behaviour. Cost: backports
kernels get less security-team attention than the stable kernel.

## 4. Other structural obstacles

1. **bash-completion.** VyOS pins 2.8 because the vyatta-bash completion engine breaks on
   newer versions. Trixie has 2.16. The VyOS trixie PRs touched vyatta-bash for this; you
   would inherit or redo that work. This is the one item that blocks even booting a usable CLI.
2. **unionfs-fuse.** Gone from trixie. vyatta-cfg uses it for config sessions (14 references).
   Either keep self-building it (VyOS already does, via fpm from upstream v3.6) or port
   vyatta-cfg to overlayfs.
3. **live-boot fork from 2015.** The image layout (`/boot/<image>/rw`, persistence, squashfs
   per image, `add system image` upgrades) lives in a fork that has diverged from Debian's
   live-boot for a decade. Debian's live-boot 20250815 will not boot a VyOS image. Keep the fork.
4. **Kea packaging names and hooks.** vyos-1x depends on `isc-kea-dhcp4` etc. (ISC's own
   naming). Debian uses `kea-dhcp4-server`, `kea-dhcp6-server`, `kea-dhcp-ddns-server`,
   `kea-ctrl-agent`. Hook path `/usr/lib/<triplet>/kea/hooks/` matches. Templates use
   `libdhcp_ha`, `libdhcp_run_script`, `libdhcp_ping_check`, `libdhcp_lease_cmds`; verify all
   four ship in Debian's kea-dhcp4-server.
5. **Version floors in vyos-1x `debian/control`** that trixie fails: `podman >= 5.8`,
   `strongswan >= 6.0.6` (and all 8 strongswan sub-packages), `telegraf >= 1.20` (not packaged).
   Everything else (`frr >= 10.2`, `ethtool >= 6.10`, `radvd >= 2.20`, `ddclient >= 3.11.1`,
   `netavark >= 1.14`, `tzdata >= 2025b`) is satisfied by trixie.

## 5. What it would take

### Repositories to fork and keep in sync with `rolling`

vyos-build, vyos-1x, vyatta-cfg, vyatta-bash, vyatta-biosdevname, vyos1x-config, vyos-utils-misc,
vyos-http-api-tools, vyos-cloud-init, live-boot, vyos-live-build, hvinfo, ipaddrcheck,
libnss-mapuser, libpam-radius-auth, libpam-tacplus, libnss-tacplus, libtacplus-map, shim-signed.
vyos-1x merges several PRs a day; this sync is the dominant ongoing cost.

### Infrastructure you must create (VyOS keeps this private)

- A package build pipeline equivalent to `vyos-build-packages` (GitHub Actions or a
  Debian sbuild farm), because `scripts/package-build/build.py` only builds one package at a
  time and assumes the bookworm container.
- A signed apt repository (aptly or reprepro) replacing `packages.vyos.net/repositories/rolling`.
- A Secure Boot story: Debian's signed kernel and shim work out of the box, but any DKMS
  module (accel-ppp, nat-rtsp, ipt-netflow, jool) then needs MOK enrolment or Secure Boot off.

### Engineering work, in order

1. Switch `data/defaults.toml` and `docker/Dockerfile` to trixie; mine the closed PR
   vyos-build#978 and its linked PRs (vyos-1x#4576, vyos-http-api-tools#25, vyatta-cfg#104,
   vyatta-bash#15) for the already-solved breakage.
2. Fix vyatta-bash against bash-completion 2.16 (or vendor 2.8 as one more overlay package).
3. Delete class C from `scripts/package-build/`; rename Depends for kea and the Prometheus
   exporters; relax `podman` to >= 5.4 or backport 5.8 from forky.
4. Kernel: drop `linux-kernel/` entirely, depend on `linux-image-amd64` from trixie-backports,
   add DKMS packages for accel-ppp, nat-rtsp; use Debian's `iptables-netflow-dkms` and
   `jool-dkms`. Patch `vyos/ifconfig/interface.py` so `link_detect` is a no-op when the sysctl
   is absent, and remove or warn on the CLI node.
5. Per-feature decisions for class D: drop BGP-LS from `interface-definitions` (or carry
   FRR yourself), rewrite or drop DMVPN, drop `dhcpv6-options no-release` and per-interface DUID
   (or switch the client to dhcpcd), drop `system option fips`, accept dropbear without PAM.
6. Overlay package set that remains self-built: class A (18 repos) + class B (roughly 15
   packages you choose to keep) + strongswan 6.0.7 from sid if you keep DMVPN.
7. Run the smoketest suite (`make test` in vyos-build) and delete or adapt failing tests.

### Effort

Getting a booting, CLI-usable image on trixie with the overlay set: weeks for one person
familiar with Debian packaging, mostly on bash-completion, kea renames and the kernel swap.
Reaching feature parity minus the class D losses and a green smoketest run: a few months.
Ongoing: tracking `rolling` daily while your base diverges from theirs, until VyOS finishes
T7557, at which point the delta collapses to the overlay set and class D choices.

## 6. Bottom line

- The package version gap is small. Debian trixie plus trixie-backports covers most of the
  43 self-built groups at or near the versions VyOS uses, and the stock Debian kernel config
  covers 776 of 796 options VyOS asks for. Security updates for frr, strongswan, kea, openvpn,
  nginx, haproxy, squid, suricata, openssl, and the kernel would come from the Debian security
  team instead of a VyOS rebuild. That is the win.
- The compromises are specific features, not versions: BGP-LS, DMVPN, DHCPv6 client
  `no-release`/per-interface DUID, WWAN DHCP over raw-IP, OpenSSL FIPS, `disable-link-detect`,
  OpenVPN DCO on a 6.12 kernel, Intel out-of-tree driver extras, and Secure Boot for DKMS modules.
- What cannot be moved to Debian regardless: the roughly 18 VyOS-native repos and the
  2015-era live-boot fork. Those are the permanent overlay.
- The single biggest hidden cost is not packaging but the private package CI you have to
  rebuild and the daily `rolling` sync. Waiting for, or contributing to, VyOS's own trixie
  migration (T7557) removes most of the porting work from your plate.

## 7. Scoped-down variant (2026-09-02): OSPF/BGP, DHCP, NAT, firewall with GeoIP

Decision by the user: drop custom packages and features in exchange for native Debian updates.
Keep IPv4/IPv6 routing (OSPF, BGP), standard DHCP, NAT, firewall incl. GeoIP. Drop podman.

### Kept, straight from Debian trixie (+ trixie-backports where noted)

| Function | Debian package(s) | Notes |
|---|---|---|
| Routing | frr 10.3, frr-pythontools, frr-snmp, frr-rpki-rtrlib | Debian build enables snmp, rpki, scripting, pathd, bfdd, pim6d. Loses only VyOS BGP-LS and a handful of pathd/ospf6d fixes. |
| Kernel | linux-image-amd64 (6.12 stable, or 7.1 backports) | All firewall/NAT/routing options present in-tree. Only `disable-link-detect` needs a code guard. |
| Firewall/NAT | nftables 1.1.3, libnftnl, conntrack, conntrackd, nfct, libndp-tools | Newer than what VyOS builds. |
| GeoIP | none extra | Implemented entirely in vyos-1x Python (`python/vyos/geoip.py`), downloads DB-IP CSV or MaxMind, renders nftables sets. Kept. |
| DHCPv4/v6 server | kea 3.0.3 from trixie-backports (or 2.6.3 stable) | Rename Depends `isc-kea-*` to `kea-dhcp4-server`, `kea-dhcp6-server`, `kea-dhcp-ddns-server`, `kea-ctrl-agent`. |
| DHCP relay | isc-dhcp-relay 4.4.3 | Unchanged version. |
| DHCP clients | isc-dhcp-client, wide-dhcpv6-client | Lose `no-release`, per-interface DUID, WWAN raw-IP. |
| RA, NDP proxy | radvd 2.20, ndppd | Same versions. |
| VRRP | keepalived 2.3.3 | Same version. |
| Everything else in the Depends list | iproute2, ethtool, openssh, chrony, rsyslog, nginx-light, pdns-recursor, haproxy, lldpd, snmpd, tcpdump, mtr, etc. | Already Debian packages in VyOS today. |

### Dropped (remove Depends, delete the matching `interface-definitions/*.xml.in`)

container (podman, netavark, aardvark-dns), vpp/dpdk, accel-ppp (pppoe-server, l2tp, sstp,
ipoe), telegraf, zabbix, zerotier, hsflowd/sflow, owamp/twamp, node/frr/blackbox exporters,
amazon and azure and xen agents, aws-gwlbtun, suricata IDS, squid webproxy, ocserv, openvpn-otp,
wwan/modemmanager, wireless/hostapd, lcdproc, tacacs and radius login, cloud-init, FIPS,
Intel out-of-tree drivers, QAT, nat-rtsp, ipt-netflow (or use `iptables-netflow-dkms`), jool
(or `jool-dkms`), Secure Boot via VyOS shim (use Debian's shim + signed kernel, or disable).

### Must still be built and maintained (the permanent overlay)

| Package | Why it cannot come from Debian |
|---|---|
| vyos-1x | The OS itself. Fork carries: trimmed `debian/control`, deleted XML for dropped features, `link_detect` guard, kea package rename. |
| vyatta-cfg | Config backend (CStore). Depends on unionfs-fuse. |
| unionfs-fuse | Removed from Debian after bookworm. Build from upstream v3.6 as VyOS does. |
| vyatta-bash | CLI shell. Must be made to work with bash-completion 2.16 (or vendor 2.8). |
| vyos1x-config / libvyosconfig0 | OCaml config parser. |
| vyos-utils | OCaml validators. |
| ipaddrcheck | Validator binary. |
| vyatta-biosdevname | Interface naming. |
| hvinfo | Ada, `show version` hypervisor detection. Could be stubbed. |
| vyos-http-api-tools | FastAPI/ariadne venv. trixie has fastapi 0.115 but not ariadne. Keep, or drop the HTTP API. |
| live-boot (fork), vyos-live-build (fork) | Boot chain and image layout. |
| python3-vici | Only if IPsec is kept. |

Roughly 11 packages, all small and slow-moving except vyos-1x. The vyos-1x delta is the only
piece that needs rebasing on every `rolling` sync.

## 8. unionfs-fuse: replacement options (2026-09-02)

How vyatta-cfg uses it: each config session union-mounts `changes/<sid>` (rw) over `active`
(ro) at `work/<sid>` by exec'ing `/usr/bin/unionfs-fuse -o cow -o allow_other` as the user
(no setuid helper; two call sites: `src/cstore/unionfs/cstore-unionfs.cpp:do_mount` and
`src/common/unionfs.c:sys_mount_session`). Deletion detection compares `active` against the
merged view, which is union-agnostic. But the legacy commit walker (`unionfs.c:retrieve_data`)
and `cstore commitConfig` also read the *change directory directly*, and only know to skip
unionfs-fuse's `.unionfs-fuse/` metadata dir and the aufs-era `.wh.__dir_opaque` marker.

| Option | Verdict |
|---|---|
| Keep building unionfs-fuse (upstream v3.x, libfuse3) | **Recommended.** Upstream active (last push 2026-07). Debian dropped only its stale 1.0 packaging. VyOS already builds it with a 15-line fpm recipe. Zero code changes. |
| fuse-overlayfs 1.14 (in trixie, unprivileged) | Feasible but needs C/C++ work: swap the two exec sites, add a `workdir`, and teach the change-dir walkers to ignore whiteouts (`.wh.<name>` files, or 0:0 char devices when mknod is permitted; 1.14 already falls back to `.wh.` files when mknod fails). Must test set/delete/discard/commit-confirm/load. |
| Kernel overlayfs | Most invasive: needs root (sessions mount as the user), a workdir on the same fs, and the same whiteout patch. Not worth it. |
| mergerfs (in trixie) | No copy-on-write whiteouts, cannot represent deletions. Unsuitable. |
| vyconf backend | The real long-term answer: in-memory sessions in an OCaml daemon, no union mount at all. Present in rolling as an opt-in test mode (`/run/vyconf_backend` sentinel, `vyconfd.service`, 15 files in vyos-1x), README still says not usable. Track it; do not base the fork on it yet. |

HTTP API dropped per user decision: removes `vyos-http-api-tools` from the overlay.
