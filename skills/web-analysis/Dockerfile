FROM node:22-alpine

# Install system dependencies for headless browsing and CLI tools
RUN apk add --no-cache \
    chromium \
    chromium-chromedriver \
    curl \
    jq \
    ca-certificates

# Set Chromium/Puppeteer environment variables
ENV CHROMIUM_PATH=/usr/bin/chromium-browser
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# Install Node.js tools globally
RUN npm install -g \
    @axe-core/cli \
    lighthouse \
    pa11y \
    broken-link-checker \
    html-validate \
    && npm cache clean --force

WORKDIR /work

COPY pa11y.json /work/pa11y.json

CMD ["sh"]
