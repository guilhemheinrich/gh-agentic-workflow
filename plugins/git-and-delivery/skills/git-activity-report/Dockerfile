ARG PYTHON_VERSION=3.10
FROM python:${PYTHON_VERSION}-alpine

RUN apk add --no-cache ca-certificates git openssh-client \
  && git config --system --add safe.directory '*'

WORKDIR /repo

COPY scripts/collect_git_activity.py /usr/local/bin/collect_git_activity
RUN chmod 0755 /usr/local/bin/collect_git_activity

ENTRYPOINT ["collect_git_activity"]
