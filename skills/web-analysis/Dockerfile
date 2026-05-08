FROM node:20-alpine

# Install system dependencies for headless browsing and CLI tools
RUN apk add --no-cache \
    chromium \
    curl \
    jq \
    ca-certificates

# Set Chromium/Puppeteer environment variables
ENV CHROMIUM_PATH=/usr/bin/chromium-browser
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# Install Node.js tools globally
RUN npm install -g \
    lighthouse \
    pa11y \
    broken-link-checker \
    @html-validate/cli \
    && npm cache clean --force

WORKDIR /work

ENTRYPOINT ["/bin/sh", "-c"]
