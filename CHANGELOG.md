# Changelog

## v1.0.0 (2026-10-22)

First tagged release.

- secure-vps.sh: apt and dpkg run non-interactively (`DEBIAN_FRONTEND=noninteractive`, keep local config files). With `--yes`, the new user is created without prompts and unattended-upgrades is configured without a dialog.
- secure-vps.sh: an existing fail2ban `jail.local` or `jail.d/sshd.local` is never overwritten.
- README states the scripts are Linux only.
- Add a CI workflow (bash -n and shellcheck).
