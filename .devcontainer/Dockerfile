FROM node:22-bookworm
RUN apt-get update && apt-get install --no-install-recommends -y awscli postgresql-client docker.io pipx less iputils-ping
RUN pipx install aws-sam-cli && pipx ensurepath