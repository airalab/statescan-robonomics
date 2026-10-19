# Robonomics: scan.robonomics.network deployment

Block explorer for Robonomics on Polkadot (para 3388, XRT, 9 decimals, ss58 32): https://scan.robonomics.network.

This repository is based on [opensquare-network/statescan-v2](https://github.com/opensquare-network/statescan-v2) at revision **797a56033e9052f9af3a3461aff2c283b49880aa** (2026-10-08, #1197). Two commits sit on top of upstream:
1. "Add Robonomics (para 3388) chain" — code changes:
   - `backend/packages/server/src/utils/consts/chains.js`: the `robonomics` chain, ss58 32, transfers kept in the block-scan DB;
   - `backend/packages/runtime-scan/src/scripts/seedByBisect.js`: seeds the runtime DB by bisection, see below;
   - `site/src/utils/consts/chains/robonomics.js` and `site/src/components/icons/robonomics.svg`: XRT, 9 decimals, Multisig, Proxy and Vesting modules, identity from Polkadot People;
   - `site/src/services/api.js`: API paths are resolved relative to `/api/`. Upstream's `new URL("/blocks", endpoint)` drops the sub-path, because upstream hosts the API on its own subdomain.
2. "Add Robonomics deployment" — this directory.

Updating from upstream: `git fetch upstream && git rebase <new revision>`, then rebuild the backend and the site.

## Contents of `deploy/robonomics/`
- `docker-compose.yml` — MongoDB, 6 scanners, REST and GraphQL; every container has a memory limit.
- `backend.Dockerfile` — one image for all `backend/` packages.
- `nginx/scan.robonomics.network` — vhost: static files, `/api/` → 5010, `/graphql` → 7100, certificate issued by nginx's built-in ACME.
- `.env.example` — compose settings (`WS_ENDPOINT` of the archive node); copy to `.env`, which is ignored by git.
- `site.env.production` — site build variables.
- `statescan-metrics.sh` — node_exporter metrics: scanner heights, container resources, MongoDB sizes, RWS usage.

## Where it runs
On the deploy host, `<deploy-dir>` is a clone of this repository (owned by an unprivileged user, branch `master`):
- compose: `deploy/robonomics/docker-compose.yml`, run from the repo root with `-f` (project name `statescan`); settings in `deploy/robonomics/.env`;
- `data/mongo/` — MongoDB data, ignored by git; never move or delete it, re-indexing takes about a day;
- metrics: a cron job runs `deploy/robonomics/statescan-metrics.sh` every 2 minutes with `RPC` set to the HTTP RPC of the archive node.

The scanners use a Robonomics archive node over the docker network `robonomics-docker-network`. The site's static files live in `/var/www/scan.robonomics.network`. There is no CI.

## Deploy
```bash
# backend: bump the image tag in deploy/robonomics/docker-compose.yml (x-backend.image), commit and push, then
ssh <deploy-host> 'cd <deploy-dir> \
  && git pull --ff-only \
  && TAG=$(grep -o "statescan-robonomics-backend:[^ ]*" deploy/robonomics/docker-compose.yml | head -1) \
  && docker build -f deploy/robonomics/backend.Dockerfile -t $TAG backend \
  && docker compose -f deploy/robonomics/docker-compose.yml up -d'
```

```bash
# site: built locally from the repo root
cp deploy/robonomics/site.env.production site/.env.production
cd site && GENERATE_SOURCEMAP=false node .yarn/releases/yarn-4.12.0.cjs build
rsync -a --delete build/ <deploy-host>:/var/www/scan.robonomics.network/
```

## Frontend changes
- The site code is in `site/`. Chain settings: `site/src/utils/consts/chains/robonomics.js`. Header: `site/src/components/header/`.
- Local check against the production API:
  ```bash
  cp deploy/robonomics/site.env.production site/.env.production
  cd site && node .yarn/releases/yarn-4.12.0.cjs install && node .yarn/releases/yarn-4.12.0.cjs start
  ```
  For the API to work from localhost you may need to set the endpoints in `.env.production` (or `.env.development.local`) to `https://scan.robonomics.network/api/` and `https://scan.robonomics.network/`.
- Send PRs to `master`. After a merge the site is built and deployed with the commands above.
- Robonomics event lists work through the existing filter, no backend changes needed: `/events?section=datalog&method=NewRecord`, `/events?section=rws&method=NewCall`, `/events?section=launch`, `/events?section=digitalTwin`.

## Notes
- **`USE_META=0`.** `USE_META=1` needs a separate metadata DB filled by an external opensquare tool. Without it metadata is read from the archive node.
- **Do not run runtime-scan from genesis.** It calls `state_getRuntimeVersion` for every block, i.e. millions of wasm executions, and drives the archive node to ~1100% CPU. Seed the runtime DB with the script instead:
  ```bash
  docker compose -f deploy/robonomics/docker-compose.yml run --rm --no-deps runtime-scan node src/scripts/seedByBisect.js
  ```
  The script finds all upgrades by bisection (12 versions in 3.5 minutes) and sets the scan height to finalized. runtime-scan then continues from the current block.
- **Runtime cache on the archive node.** When scanners are in different runtime eras, the node keeps recompiling wasm. Run the node with `--runtime-cache-size=16` (the default keeps 2 runtimes).
- **`SCAN_STEP=10`** — how many blocks a scanner fetches in parallel. With 50 the node on the shared host went to ~1000% CPU.
- **`NODE_ENV=docker`.** With `production`, scan-common writes logs to `log/*.log` inside the container without rotation. With any other value logs go to stdout (docker rotation 50m×3).
- **Memory limits.** The V8 heap is set explicitly with `--max-old-space-size`; otherwise Node takes ~50% of `mem_limit` and crashes on large steps.
- **Only indexed MongoDB queries.** For example, `event` by `section + method + indexer.blockHeight`. An unindexed query on `event` once got mongod OOM-killed.
- **Governance is disabled.** The home page block takes its data from the SubSquare API, and SubSquare does not support Robonomics.
