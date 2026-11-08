# syntax=docker/dockerfile:1

# ---- Stage 1: install production dependencies only ----
FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

# ---- Stage 2: minimal runtime image ----
FROM node:24-alpine AS runtime

# 1) apk upgrade: pull OS security patches released after the base image was built
#    (e.g. zlib CVE-2026-4738 was fixed in Alpine before node:24-alpine was rebuilt).
# 2) npm/npx are not needed at runtime and carry their own dependency CVEs — remove them.
RUN apk upgrade --no-cache \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx \
 && mkdir -p /data && chown node:node /data

WORKDIR /app

# Amazon RDS CA bundle: lets the app verify the database's TLS certificate.
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/certs/rds-global-bundle.pem

COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src

ARG APP_VERSION=dev
ARG GIT_SHA=local
ENV NODE_ENV=production \
    PORT=3000 \
    DATA_DIR=/data \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA}

# Never run as root inside the container.
USER node
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/healthz || exit 1

# exec form -> node is PID 1 and receives SIGTERM directly (graceful shutdown works).
CMD ["node", "src/server.js"]
