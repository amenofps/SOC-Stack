FROM node:22-bookworm AS build

WORKDIR /src
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/mitre-attack/attack-navigator.git .

WORKDIR /src/nav-app
RUN npm install
RUN npm run build -- --configuration production

FROM nginx:stable
RUN rm -f /usr/share/nginx/html/index.html
COPY --from=build /src/nav-app/dist/browser/ /usr/share/nginx/html/