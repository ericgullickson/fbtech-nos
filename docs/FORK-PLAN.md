# fbtech-nos: fork plan

fbtech-nos is a fork of VyOS (`vyos/vyos-build`, branch `rolling`) whose goal is to take as
many packages as possible from upstream Debian (trixie + trixie-backports) so that security
updates come from Debian, while keeping the VyOS CLI, config system and image layout.

Owner: ericgullickson. Repo: https://github.com/ericgullickson/fbtech-nos (public, GPL).
Detailed research: `docs/FORK-ANALYSIS.md` (read sections 7 and 8 first).

## Scope decisions (already made, do not reopen)

Keep: IPv4/IPv6 routing with OSPF and BGP (FRR), static routes, DHCPv4/v6 server (Kea) and
relay, DHCP clients, NAT, nftables firewall including GeoIP, VRRP (keepalived), SSH, NTP,
syslog, SNMP, DNS forwarding, LLDP, RA/NDP proxy, WireGuard, OpenVPN, IPsec if it comes for
free from Debian's strongswan.

Drop: containers/podman, VPP, accel-ppp (PPPoE server/L2TP/SSTP/IPoE), telegraf, zabbix,
zerotier, hsflowd, owamp/twamp, Prometheus exporters, Amazon/Azure/Xen agents, cloud-init,
suricata, squid, ocserv, openvpn-otp, WWAN, wireless, LCD, TACACS/RADIUS login, FIPS,
Intel out-of-tree drivers, QAT, nat-rtsp, VyOS Secure Boot shim, **the HTTP API**
(`vyos-http-api-tools`).

## Target architecture

| Piece | Decision |
|---|---|
| Debian base | trixie, plus `linux-image-amd64` and kea from trixie-backports |
| Kernel | Debian's, not self-built. Feature `disable-link-detect` becomes a no-op. |
| Overlay packages we build | vyos-1x, vyatta-cfg, vyatta-bash, unionfs-fuse (upstream v3.x), vyos1x-config (libvyosconfig), vyos-utils, ipaddrcheck, vyatta-biosdevname, hvinfo, live-boot (VyOS fork), live-build (VyOS fork) |
| Where they are built | GitHub-hosted runners, `debian:trixie` containers |
| Where they are published | Signed apt repository on GitHub Pages: `https://ericgullickson.github.io/fbtech-nos/` (branch `gh-pages`) |
| Build container | Trixie variant of `docker/Dockerfile`, pushed to `ghcr.io/ericgullickson/fbtech-nos-build` |
| ISO build | GitHub Actions, `ubuntu-24.04`, privileged container, `./build-vyos-image generic`, ISO attached to a GitHub Release |
| Architecture | amd64 first |

## Milestones

1. **Baseline ISO in CI.** Build the unmodified rolling ISO with VyOS's own public package
   mirror (`https://packages.vyos.net/repositories/rolling/`) and container
   (`vyos/vyos-build:rolling`) in GitHub Actions, attach it to a release. Proves the pipeline.
   Reference: `.github/workflows/package-smoketest.yml` job `build_iso` in this repo.
2. **Package pipeline.** Workflow that builds the overlay packages on trixie and publishes the
   signed apt repo to GitHub Pages. Start with the easy ones (unionfs-fuse, ipaddrcheck,
   vyatta-biosdevname, hvinfo), then vyos1x-config and vyos-utils (OCaml), then vyatta-cfg,
   vyatta-bash, vyos-1x, live-boot, live-build.
3. **Trixie build base.** `data/defaults.toml` -> trixie, trixie Dockerfile, remove the
   `scripts/package-build/` entries we no longer build, Debian kernel + firmware instead of
   `linux-image-<ver>-vyos` and `vyos-linux-firmware`.
4. **vyos-1x fork.** Trim `debian/control` (drop the features above, rename Kea packages to
   Debian's `kea-dhcp4-server`, `kea-dhcp6-server`, `kea-dhcp-ddns-server`, `kea-ctrl-agent`),
   delete the matching `interface-definitions/*.xml.in`, guard `link_detect` in
   `python/vyos/ifconfig/interface.py`, fix vyatta-bash for bash-completion 2.16.
5. **Trixie ISO** built from Debian + our apt repo, boots to the VyOS CLI, `make testc` passes.

## Conventions

- `rolling` tracks upstream `vyos/vyos-build` untouched. `main` is our default branch.
  Feature work goes on branches and is merged to `main`.
- Component forks, when needed, are named `ericgullickson/fbtech-nos-<component>`
  (e.g. `fbtech-nos-1x`, `fbtech-nos-vyatta-cfg`).
- Commit messages: `<component>: <short description>`. End every commit with

      Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
      Claude-Session: https://claude.ai/code/session_01CWTm7nyAqDV739ZNDzKsqC

- Push over SSH (`git@github.com:ericgullickson/fbtech-nos.git`). The `gh` token lacks the
  `workflow` scope, so HTTPS pushes of `.github/workflows/*` are rejected; SSH is fine.
- GitHub Actions on this public repo are free. Runner limits: about 14 GB free disk on `/`,
  6 hours per job. Use `--privileged` for live-build.
- Do not touch `packages.vyos.net` credentials or private VyOS repos; only public sources.
- Never rewrite history on `main` or `rolling`.
