# Milestone 4: the vyos-1x fork

Trims `vyos/vyos-1x` down to the scope decided in `docs/FORK-PLAN.md` /
`docs/FORK-ANALYSIS.md` section 7, and makes it build on Debian trixie in
`ghcr.io/ericgullickson/fbtech-nos-build:trixie`, producing `vyos-1x`,
`vyos-1x-smoketest`, `vyos-1x-vmware` and `libvyosconfig0`.

Fork: https://github.com/ericgullickson/fbtech-nos-1x, branch `fbtech`
(pinned commit `ce97c1c468a913bebd95236704800e99e7db7c29` as of this
writing - `overlay/vyos-1x/build.sh` pins its own commit; check there for
the current value).

## What was removed

`debian/control` Depends/Pre-Depends and the matching
`interface-definitions/*.xml.in` (plus their `src/conf_mode/*.py` and
`smoketest/scripts/cli/test_*.py`) were deleted for every feature
`docs/FORK-PLAN.md` drops:

| Feature | Interface definitions removed | Packages removed |
|---|---|---|
| Container (podman) | `container.xml.in` | `podman`, `netavark`, `aardvark-dns`, `iptables` |
| VPP | `vpp.xml.in` + 7 `vpp_interface_*.xml.in`/`vpp_*.py` | `libvppinfra`, `python3-vpp-api`, `vpp`, `vpp-crypto-engines`, `vpp-dev`, `vpp-plugin-core`, `vpp-plugin-dpdk` |
| accel-ppp VPN servers | `vpn_l2tp.xml.in`, `vpn_pptp.xml.in`, `vpn_sstp.xml.in`, `service_ipoe-server.xml.in`, `service_pppoe-server.xml.in` | `accel-ppp-ng` |
| Wireless | `interfaces_wireless.xml.in`, `system_wireless.xml.in` | `hostapd`, `hsflowd`, `iw`, `wireless-regdb`, `wpasupplicant` |
| WWAN | `interfaces_wwan.xml.in` | `modemmanager`, `usb-modeswitch`, `libqmi-utils` |
| OpenVPN OTP | (leafNode only, `interfaces_openvpn` kept) | `openvpn-otp` |
| IDS | (Depends only, no dedicated xml.in) | `suricata`, `suricata-update` |
| Web proxy | `service_webproxy.xml.in` | `squid`, `squidclient`, `squidguard` |
| Monitoring exporters | `service_monitoring_prometheus.xml.in`, `service_monitoring_telegraf.xml.in`, `service_monitoring_zabbix-agent.xml.in` | `node-exporter`, `frr-exporter`, `blackbox-exporter`, `telegraf`, `zabbix-agent2` |
| SLA (OWAMP/TWAMP) | `service_sla.xml.in` | `owamp-client`, `owamp-server`, `twamp-client`, `twamp-server` |
| Broadcast relay | `service_broadcast-relay.xml.in` | `udp-broadcast-relay` |
| LCD | `system_lcd.xml.in` | `lcdproc`, `lcdproc-extra-drivers` |
| HTTP API | `service_https.xml.in` | `vyos-http-api-tools`, `nginx-light` |
| AWS Gateway LB | `service_aws_glb.xml.in` (plus the whole `vyos-1x-aws` binary package, its systemd unit and Jinja template) | `aws-gwlbtool` (never a Debian package to begin with) |
| VyOS Secure Boot shim | (Depends only) | `shim-signed`, `sbsigntool` (kept `mokutil`, `grub-efi-*-signed`, see below) |
| VPN OpenConnect | `vpn_openconnect.xml.in` | `ocserv` |
| sFlow | `system_sflow.xml.in` | (was bundled with the wireless block above) |
| TACACS+/RADIUS login | radius/tacacs nodes inside `system_login.xml.in` (file kept, other login features unaffected) | `libnss-tacplus`, `libpam-tacplus`, `vyos-libpam-radius-auth`, `vyos-libnss-mapuser` |
| FIPS | `fips` leafNode inside `system_option.xml.in` (file kept) | (was never a separate Debian package; VyOS's own FIPS-patched openssl) |
| nat-rtsp | `rtsp` leafNode inside `system_conntrack.xml.in` (file kept; sibling `pptp`/`sip`/etc. helpers use Debian's stock `nf_conntrack_*` modules and are unaffected) | `nat-rtsp` (VyOS-only DKMS module, not packaged for Debian) |

Conf_mode scripts and smoketests for whole-feature removals above are
**deleted outright**, not left in place: `Makefile`'s
`generate-configd-include-json` target lists every file physically
present under `src/conf_mode/` with no reference to whether an
`interface-definitions/*.xml.in` still points at it, so an orphaned
script would still be imported unconditionally by `vyos-configd` at
startup. Deleting the file is what actually keeps it out of
`data/configd-include.json`.

`debian/vyos-1x.postinst` also drops `adduser <user> vpp` (the `vpp`
group no longer exists once `vpp`'s Depends are gone) and a vestigial
`node_exporter` system-user block.

## What was renamed

- **Kea**: `isc-kea-dhcp4`/`isc-kea-dhcp6`/`isc-kea-dhcp-ddns`/
  `isc-kea-hooks` -> Debian's `kea-dhcp4-server`/`kea-dhcp6-server`/
  `kea-dhcp-ddns-server`/`kea-common`. Verified against Debian's
  `Contents-amd64` index (not `packages.debian.org`, which anti-bot-gates
  plain `curl`): `kea-common` in trixie (kea 2.6.3) ships
  `libdhcp_ha.so`, `libdhcp_lease_cmds.so`, `libdhcp_run_script.so`, but
  **not** `libdhcp_ping_check.so` - that only appears in
  trixie-backports' kea 3.0.3 `kea-common`. `docs/FORK-ANALYSIS.md`
  already recommends trixie-backports' kea for other reasons (matching
  VyOS's own 3.0.x); this makes it load-bearing, not just nice-to-have,
  if HA ping-check is used. `kea-ctrl-agent` was not added - nothing in
  vyos-1x's templates or conf_mode references the Kea control agent.
  Also renamed: the `isc-kea-dhcp{4,6,-ddns}-server(@vrf)` systemd unit
  filenames vyos-1x ships under `src/etc/systemd/system/` (both the
  `@.service` VRF-instance templates and the `.service.d` drop-ins for
  the base units), and every matching service-name string in
  `src/op_mode/{dhcp,restart}.py`, `src/conf_mode/service_dhcp{,v6}-server.py`
  and `op-mode-definitions/{monitor,show}-log.xml.in`.
- **jool -> jool-tools + jool-dkms**: trixie packages both trivially
  (`jool` itself is only the source package name), so nat64 is kept per
  `docs/FORK-PLAN.md`'s "unless trivial" clause.
- **strongswan version floor 6.0.6 -> 6.0.1**: the 6.0.6 bump (upstream
  commit `T8099: update strongswan dependency to 6.0.6`) was entirely for
  ML-KEM post-quantum DH groups (`dh-group33`/`34`/`35`, added by the
  companion commit `T8099: strongswan: Post quantum options`). trixie
  ships strongswan 6.0.1. Every other `vpn ipsec` feature - including
  DMVPN's vici-initiate override, which is a patch VyOS carries on top of
  strongswan and this fork does **not** carry, since we're taking
  strongswan straight from Debian - works with 6.0.1. Only selecting
  `dh-group33`/`34`/`35` for ESP/IKE PFS will fail at runtime with an
  unsupported-group error from a stock trixie strongswan.
- `python/vyos/utils/serial.py`, `src/conf_mode/system_option.py`,
  `src/systemd/stunnel.service` -> `stunnel4.service`,
  `src/init/vyos-router`: see the "pick up remaining trixie fixes from
  upstream's closed T7557 PR" commit - utmp/`localectl`/dmesg-loglevel
  fixes mined from `vyos/vyos-1x#4576` (T7557), which itself was closed
  unmerged, but two of its other concerns already landed separately
  upstream (nose2 in #4728, SSH DSA deprecation in #4731, both already
  present on `rolling` and therefore inherited by this fork unchanged).

## pylint 3.x and Python 3.13

`debian/rules`' `make all` chain runs `pylint --errors-only`
(`Makefile`'s `pylint` target), which fails the whole build on any
E-level finding. trixie ships pylint 3.3.4 (bookworm has 2.x); its
stricter control-flow analysis (`possibly-used-before-assignment`,
E0606) surfaced about a dozen pre-existing sites - none on dropped
features - where a variable is only assigned on some branches of an
if/elif chain but used unconditionally afterwards (e.g.
`src/conf_mode/firewall.py`, `python/vyos/nat.py`,
`src/conf_mode/vpn_ipsec.py`, several `src/op_mode/*.py` files). Each
was fixed either by initializing the variable before the branch (when
the branches are mutually exclusive and exhaustive by construction but
pylint can't prove it across separate `if`s), or with a targeted
`# pylint: disable=possibly-used-before-assignment` at the call site
for the handful of cases where a module-level global is assigned in
`if __name__ == '__main__':` and always initialized before the
function using it runs (a pattern used throughout VyOS's op-mode
scripts). `src/services/vyos-netlinkd` additionally hit
`unexpected-keyword-arg`/`too-many-function-args` for two pyroute2
calls that are already wrapped in a `TypeError` fallback for older
pyroute2 versions - also silenced inline, not restructured.

Separately, **not** a pylint finding but a real Python 3.13 break:
`src/op_mode/show_users.py` imported the `spwd` module, removed from
the standard library in 3.13 (PEP 594). `is_locked()` now reads
`/etc/shadow` directly instead, same data and privilege requirement.

## `python/vyos/ifconfig/interface.py`: `link_detect`

`Interface.set_link_detect()` now checks whether
`/proc/sys/net/ipv4/conf/<ifname>/link_filter` exists before touching it,
and is a no-op (logged once at debug level) if not - the CLI node
(`disable-link-detect`) stays. This sysctl is a VyOS kernel patch absent
from stock Debian kernels.

## Version

vyos-1x does not read its `.deb` `Version:` from `debian/changelog` at
all - `debian/rules`' `override_dh_gencontrol` passes
`-v$(BASE_VERSION)-$(COMMIT_COUNT)-$(COMMIT_ID)$(DIRTY_FLAG)` to
`dh_gencontrol`, and `BASE_VERSION` was a hardcoded `999.0` (the
changelog's own placeholder entry says as much: "the correct version
number is auto-generated by GIT on build-time"). `BASE_VERSION` is now
`1.5.0+fbtech1`, so built packages version as
`1.5.0+fbtech1-<commit_count>-g<sha>[-dirty]`, distinct from upstream
VyOS's own `999.0-<count>-g<sha>` packages.

## Build recipe (this repo)

- `overlay/vyos-1x/image`: `ghcr.io/ericgullickson/fbtech-nos-build:trixie`
  - vyos-1x needs the full build toolchain (OCaml/opam for
    `libvyosconfig0`, `syft`, the whole vyos-1x Python build-dep list),
    which only that image has; bare `debian:trixie` (used by the other
    four overlay packages today) is not enough.
- `overlay/vyos-1x/deps`: empty. Nothing in this build needs another
  overlay package installed first - `vyatta-cfg`/`vyatta-bash`/etc. are
  runtime Depends of the built `vyos-1x` package, not build-time
  dependencies of building it.
- `overlay/vyos-1x/build.sh`: clones `fbtech-nos-1x` at the pinned commit
  above, verifies it, runs `mk-build-deps --install` against
  `debian/control` (belt-and-suspenders on top of what the image already
  has), then `dpkg-buildpackage -us -uc -b`, and copies every `*.deb`
  produced into `$OUT_DIR`.
  - `debian/rules`' `make all` chain reaches `libvyosconfig/Makefile`'s
    `depends` target, which does
    `opam pin add vyos1x-config https://github.com/vyos/vyos1x-config.git#<sha>`
    (and the same for `vyconf`) via `sudo`, at build time. Neither VyOS's
    own `docker/Dockerfile` nor ours bakes these opam packages into the
    image - confirmed against both `origin/trixie-base` and the real
    `vyos/vyos-build`'s `docker/Dockerfile` - so this genuinely happens
    on every build, over the network, inside `libvyosconfig`'s own
    Makefile. It needs outbound network access to github.com and a user
    with passwordless sudo; both hold for `fbtech-nos-build:trixie`'s
    default user. This is a real, if slow, part of "the container
    provides the OCaml artefacts under /opt/opam/<version>" - it
    provides the *toolchain* (opam/OCaml/ctypes/etc.), the two VyOS-only
    OCaml packages are fetched and pinned into it at vyos-1x build time,
    not baked into the image layer.
  - `make all` also runs `pylint` and (via the `test` target) `python3 -m
    nose2 -v`, so the unit tests debian/rules already runs happen as an
    ordinary part of this build with no separate step needed.

## Remaining unsatisfiable/weakened Depends

- **`python3-vici`**: dropped entirely. Debian does not package it at
  all (confirmed: strongswan's trixie source package builds
  `charon-systemd`, `strongswan-swanctl`, `libcharon-extra-plugins`, etc.
  but no `python3-vici`). It is only imported by
  `src/op_mode/ipsec.py`/`vpn_ike_sa.py` (`show vpn ipsec sa`, `show vpn
  ike sa`) via `python/vyos/ipsec.py` - **conf_mode IPsec (writing
  swanctl config, bringing tunnels up) does not need it**. Those two
  op-mode status commands will fail with an ImportError until
  `python3-vici` is built as an overlay package (flagged as a "must
  still be built" item in `docs/FORK-ANALYSIS.md` section 7, but out of
  this milestone's scope).
- **ML-KEM IPsec groups**: `dh-group33`/`34`/`35` in `vpn_ipsec`'s
  PFS/proposal CLI nodes will be accepted by the CLI (the XML wasn't
  touched) but rejected by strongswan 6.0.1 at apply time. Either strip
  those three CLI choices, or take strongswan from a newer suite, if this
  matters to whoever picks this up next.
- **Kea `@vrf` systemd instances**: Debian's `kea-dhcp4-server`/
  `kea-dhcp6-server`/`kea-dhcp-ddns-server` packages ship only a plain,
  non-templated `<name>.service` unit (verified against both trixie's
  and trixie-backports' `Contents-amd64`, no `kea-dhcp4-server@.service`
  in either). vyos-1x supplies its own `kea-dhcp4-server@.service` (etc.)
  instance templates and `.service.d` overrides under
  `src/etc/systemd/system/` specifically so VRF instances keep working -
  this is unaffected by the rename (it's vyos-1x's own unit, not
  Debian's), but is worth calling out since it means those three package
  names are Depends purely for the binaries/hook libraries, not for
  their own bundled units.

## Open items for whoever picks this up next

1. **`python/vyos/container.py` and `src/op_mode/container.py`** (the
   `show container ...` op-mode commands) were left in place - they were
   out of this milestone's stated scope (`interface-definitions/` +
   matching conf_mode/smoketest only). They still reference `podman`
   and will raise or no-op ungracefully if invoked on a system with no
   container Depends installed. Same story for a handful of orphaned
   `src/systemd/*.service` files with zero remaining references
   (`LCDd.service`, `lcdproc.service`, `podman.socket`,
   `vpp-failure-handler.service`) and orphaned `data/templates/{telegraf,vpp,container}/`
   Jinja templates - all dead weight, none of them can fail a build or
   an install (debian/rules copies whole directories with plain `cp -r`,
   so a stray template file is silently packaged, not an error), but
   they are still there.
2. **`smoketest/configs/*` fixtures** (`container-simple`, `wireless-basic`,
   `ipoe-server`, `vpn-openconnect-sstp`, etc.) were not scrubbed of
   dropped-feature stanzas. This milestone's verification bar was the
   `nose2` unit tests debian/rules runs during the build, not the full
   `make testc` / smoketest-config-load suite, so this wasn't addressed
   here. `docs/FORK-ANALYSIS.md`/`docs/FORK-PLAN.md` do not currently
   commit to running `make testc` before milestone 5's trixie ISO.
3. **`debian/vyos-1x.preinst`**'s `dpkg-divert ... /etc/sysctl.d/80-vpp.conf`
   is harmless (idempotent, doesn't fail if vpp is never installed) but
   is vpp-specific dead code, same category as item 1.
4. **`test_system_login.py`/`test_system_option.py`** were not edited to
   remove their tacacs/radius/fips-specific test cases (only the CLI
   nodes those tests exercise were removed). If `nose2` collects and
   runs the full `smoketest/scripts/cli/` tree as unit tests (it does
   not by default - `nose2.cfg`'s `start-dir = src` only covers
   `src/tests`, not `smoketest/`), this would not surface during the
   package build; it would only matter for a future `make testc` run.
5. **Build verification status:** a first `docker run -m 2500m
   ghcr.io/ericgullickson/fbtech-nos-build:trixie` against the pinned
   `fbtech-nos-1x` commit got all the way through `opam pin`/OCaml
   compilation of `libvyosconfig0`, `interface_definitions`/template
   generation (validating this milestone's XML deletions and the
   `system_login`/`system_option` partial edits), and into
   `dpkg-buildpackage`, then failed on `make pylint` - see "pylint 3.x
   and Python 3.13" above for the fix, now committed as
   `fbtech-nos-1x@d72243b18441951f463419fb4c76e9a127634396` and pinned
   in `overlay/vyos-1x/build.sh`. See the final report for the result of
   the `build-packages.yml` run against this commit.
