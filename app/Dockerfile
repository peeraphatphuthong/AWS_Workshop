# syntax=docker/dockerfile:1

# ---- Stage 1: install production dependencies only ----
FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

# ---- Stage 2: minimal runtime image ----
FROM node:24-alpine AS runtime

# npm/npx are not needed at runtime and carry their own dependency CVEs — remove them.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx \
 && mkdir -p /data && chown node:node /data

WORKDIR /app
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
