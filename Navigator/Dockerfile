FROM node:22-bookworm AS build

WORKDIR /src
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/mitre-attack/attack-navigator.git .

WORKDIR /src/nav-app
RUN npm install
RUN npm run build -- --configuration production

RUN rm -rf /tmp/navigator-webroot && mkdir -p /tmp/navigator-webroot \
    && cp -a /src/nav-app/dist/browser/. /tmp/navigator-webroot/

FROM nginx:stable
RUN rm -rf /usr/share/nginx/html/*
COPY --from=build /tmp/navigator-webroot/ /usr/share/nginx/html/