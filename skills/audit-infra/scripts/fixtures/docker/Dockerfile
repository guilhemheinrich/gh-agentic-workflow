# FIXTURE, deliberately bad. Do not build. Detection targets for hadolint and trivy:
# floating base tag, root user, apt without pinning or cleanup, ADD from a URL,
# no HEALTHCHECK, shell-form CMD.
FROM node:latest
RUN apt-get update && apt-get install -y curl
ADD https://example.test/tool.tar.gz /opt/
COPY . /app
WORKDIR /app
RUN npm install
EXPOSE 3000 22
CMD npm start
