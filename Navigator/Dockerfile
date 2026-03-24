FROM node:22-bookworm AS build

WORKDIR /app
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/mitre-attack/attack-navigator.git .
RUN npm install
RUN npm run build

FROM nginx:stable
COPY --from=build /app/dist/ /usr/share/nginx/html/