# Contributing

Thanks for helping out. A few ground rules keep the toolkit easy to trust:

- One script, one job. Put it in the matching category folder.
- Start with a header comment: what it does, usage, and a link to the related article if there is one.
- Use `set -euo pipefail` and support `--help`.
- Read-only by default. Anything that changes the system asks for confirmation (or offers `--dry-run`).
- No secrets, tokens, real IPs or customer data in code or examples.
- Run `bash -n` and `shellcheck` on your script before opening a merge request.

Open an issue first for bigger changes so the approach can be agreed on before the work starts.
