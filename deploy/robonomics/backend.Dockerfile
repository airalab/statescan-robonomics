# statescan-v2 backend (all workspaces) for Robonomics. Build context: backend/ of this repository (see deploy/robonomics/README.md).
FROM node:20-bookworm-slim

WORKDIR /app
COPY . .
# nodeLinker is set in the repo-root .yarnrc.yml, which is not part of this context
ENV YARN_NODE_LINKER=node-modules
# log4js writes to ./log in the package dir (cwd)
RUN node .yarn/releases/yarn-4.12.0.cjs install --immutable \
    && rm -rf .yarn/cache .pnp.* /root/.yarn /tmp/* \
    && for p in packages/*/; do mkdir -p "${p}log"; done \
    && chown -R node:node packages/*/log

ENV NODE_ENV=production
USER node
