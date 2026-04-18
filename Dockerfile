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
    && apt-get install -y --no-install-recommends openssh-client bsdutils \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "mcp[cli]>=1.0"

COPY ssh-wrapper /usr/local/bin/ssh
RUN chmod +x /usr/local/bin/ssh

COPY server.py /app/server.py

VOLUME /sessions

CMD ["sleep", "infinity"]
