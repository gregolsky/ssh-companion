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
