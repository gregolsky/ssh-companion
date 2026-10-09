# Copyright 2026 Grzegorz Lachowski
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FROM python:3.14-slim

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends openssh-client bsdutils jq \
    && rm -rf /var/lib/apt/lists/*

# Pinned: mcp 2.x renamed FastMCP and breaks server.py.
RUN pip install --no-cache-dir "mcp[cli]==1.30.0"

# Non-root user. UID/GID default to 1000 (matches most single-user Linux
# desktops). Override at build time (`--build-arg COMPANION_UID=$(id -u)
# --build-arg COMPANION_GID=$(id -g)`) if your host UID differs — the
# bind-mounted ~/.ssh and sessions dir keep their host ownership, so
# the container user must match to read keys and write session logs.
ARG COMPANION_UID=1000
ARG COMPANION_GID=1000
RUN groupadd --gid "${COMPANION_GID}" companion \
    && useradd --create-home --uid "${COMPANION_UID}" --gid "${COMPANION_GID}" companion

COPY _ssh-host.sh /usr/local/lib/ssh-companion/ssh-host.sh
COPY ssh-wrapper /usr/local/bin/ssh
RUN chmod +x /usr/local/bin/ssh

COPY server.py /app/server.py

RUN mkdir -p /sessions && chown companion:companion /sessions && chmod 700 /sessions

# ~/.ssh is mounted read-only, so new host keys go to a writable volume first
# (ssh appends to the first UserKnownHostsFile) while ~/.ssh/known_hosts is
# still consulted.
RUN mkdir -p /home/companion/.ssh-companion \
    && chown companion:companion /home/companion/.ssh-companion \
    && chmod 700 /home/companion/.ssh-companion \
    && printf 'UserKnownHostsFile /home/companion/.ssh-companion/known_hosts /home/companion/.ssh/known_hosts\n' \
        > /etc/ssh/ssh_config.d/companion.conf

USER companion
VOLUME /sessions

CMD ["sleep", "infinity"]
