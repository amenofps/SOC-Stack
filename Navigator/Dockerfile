FROM node:22-bookworm AS build

WORKDIR /src
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/mitre-attack/attack-navigator.git .

WORKDIR /src/nav-app
RUN npm install
RUN npm run build

FROM nginx:stable
COPY --from=build /src/nav-app/dist/ /usr/share/nginx/html/