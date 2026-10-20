<p align="center"><img src="assets/logo.png" alt="Pro Gineous" width="360"></p>

# Pro Gineous Server Toolkit

Small, readable scripts for the jobs that come up again and again on a server: locking down a fresh VPS, checking what is listening, watching domain expiry, reading DMARC reports, fixing WP-Cron and backing up WordPress. Each script comes from a walkthrough on the [Pro Gineous blog](https://blog.progineous.com), so the article explains the why and the script handles the typing.

Everything is plain Bash, has a `--help` flag, and is read-only unless you pass an option that changes something. Even then it asks first.

## Tools

| Tool | What it does | Related article |
|------|--------------|-----------------|
| [vps-hardening/secure-vps.sh](vps-hardening/secure-vps.sh) | Step-by-step hardening for Debian/Ubuntu: updates, sudo user, SSH key-only login, UFW, fail2ban, unattended-upgrades, optional swap. Supports `--dry-run`. | [Secure a Linux VPS in 15 Minutes](https://blog.progineous.com/secure-linux-vps-15-minutes/) |
| [vps-hardening/port-audit.sh](vps-hardening/port-audit.sh) | Lists listening sockets and flags database/admin ports bound to a public address. Read-only. | [How to Secure a VPS: Keys, Ports and Updates](https://blog.progineous.com/how-to-secure-a-vps/) |
| [domains/domain-expiry.sh](domains/domain-expiry.sh) | Checks a list of domains over RDAP for expiry dates and hold/redemption/pending-delete flags. Cron friendly. | [Using RDAP to Check a Domain's Expiry Date and Lock Status](https://blog.progineous.com/rdap-domain-lookup/) |
| [domains/rdap-lookup.sh](domains/rdap-lookup.sh) | Short RDAP summary for one domain: status, lock, dates, nameservers, DNSSEC. | [Using RDAP to Check a Domain's Expiry Date and Lock Status](https://blog.progineous.com/rdap-domain-lookup/) |
| [dns/dns-compare.sh](dns/dns-compare.sh) | Asks each authoritative nameserver and two public resolvers for the same record and shows where they disagree. | [How to Read dig Output When DNS Looks Wrong](https://blog.progineous.com/read-dig-output-dns/) |
| [email/mail-auth-check.sh](email/mail-auth-check.sh) | Shows DMARC, SPF and DKIM records with a few sanity checks (one SPF record, DMARC policy, rua address). | [How to Read DMARC Reports Before You Move to p=reject](https://blog.progineous.com/read-dmarc-reports/) |
| [email/dmarc-report-summary.sh](email/dmarc-report-summary.sh) | Turns DMARC aggregate reports (.zip, .xml.gz, .xml) into one line per sending IP, sorted by volume. | [How to Read DMARC Reports Before You Move to p=reject](https://blog.progineous.com/read-dmarc-reports/) |
| [wordpress/wp-cron-check.sh](wordpress/wp-cron-check.sh) | Diagnoses missed scheduled posts with WP-CLI and can switch WP-Cron to a real cron job. | [Why WordPress Missed Your Scheduled Post](https://blog.progineous.com/wordpress-missed-schedule-wp-cron/) |
| [backups/wp-backup.sh](backups/wp-backup.sh) | Files plus database dump in one archive, disk-space check, retention with confirmation before deleting. | [How to Back Up WordPress: Files and Database](https://blog.progineous.com/how-to-back-up-wordpress/) |

## Quick start

```bash
git clone https://gitlab.com/pro-gineous-group/server-toolkit.git
cd server-toolkit
./domains/rdap-lookup.sh example.com
./vps-hardening/secure-vps.sh --dry-run      # see what would change first
```

Common dependencies: `curl`, `jq`, `dig` (dnsutils), `xmlstarlet`, WP-CLI for the WordPress tools. On Debian/Ubuntu:

```bash
sudo apt install curl jq dnsutils xmlstarlet unzip
```

## Where to run it

The scripts target current Debian and Ubuntu releases and work on any VPS or dedicated server with root access. The team tests them on [Pro Gineous](https://progineous.com) VPS plans (from $6.96/mo), which are a cheap place to spin up a scratch server and try the hardening script before touching anything that matters.

## Disclaimer

Test on a non-production server first. Keep your provider's web console open when changing SSH or firewall settings, and take a snapshot before you start. These scripts are provided as is, without warranty; see [LICENSE](LICENSE).

## Contributing

Fixes and new tools are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
