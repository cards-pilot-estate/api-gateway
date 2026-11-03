# Working on this repository (assisted sessions)

Read first: `README.md`, then in the platform repository `docs/channels/README.md` (rulings R1-R22, § API gateway) and ADR-0019.

## Rules
- One issue, one branch `<type>/<issue#>-<slug>`, one PR titled `type(scope): summary` with `Closes #<issue>`. Squash-merge only after CI is green. Record the PR in the platform's `docs/bank-grade/next-steps.md` § MG row.
- Routes are an allow-list: add a route only with the backend's contract (OpenAPI) path, an exact or regex match, a token audience and a client list. Never a prefix match.
- Never route `/api/v1/applicants/**`, `/api/v1/ops/**`, `/actuator/**`, API docs, or any `/sim-admin/**` test hook.
- Access logs carry ids only: no bodies, tokens, query strings or customer keys.
- No secrets, no real vendor or bank names.

## Commands
`make install` · `make deploy` · `make test ENV=dev` · `make lint`
