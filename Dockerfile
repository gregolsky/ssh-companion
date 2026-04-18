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

FROM python:3.12-slim

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends openssh-client bsdutils \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "mcp[cli]>=1.0"

# Non-root user. UID/GID default to 1000 (matches most single-user Linux
# desktops). Override at build time (`--build-arg COMPANION_UID=$(id -u)
# --build-arg COMPANION_GID=$(id -g)`) if your host UID differs — the
# bind-mounted ~/.ssh and sessions dir keep their host ownership, so
# the container user must match to read keys and write session logs.
ARG COMPANION_UID=1000
ARG COMPANION_GID=1000
RUN groupadd --gid "${COMPANION_GID}" companion \
    && useradd --create-home --uid "${COMPANION_UID}" --gid "${COMPANION_GID}" companion

COPY ssh-wrapper /usr/local/bin/ssh
RUN chmod +x /usr/local/bin/ssh

COPY server.py /app/server.py

RUN mkdir -p /sessions && chown companion:companion /sessions

USER companion
VOLUME /sessions

CMD ["sleep", "infinity"]
