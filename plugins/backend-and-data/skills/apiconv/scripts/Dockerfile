FROM node:22-alpine
RUN apk add --no-cache jq
WORKDIR /tool
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY apiconv.mjs bundle.sh runtime-check.sh ./
COPY schemas ./schemas
