FROM ghcr.io/amediomediagroup/upstream/node:20-bullseye@sha256:c0122351f25f04facee976f9db7214789eabadb489f4e4aea9cd00a0d6af77c4
WORKDIR /app
COPY . .
RUN npm install
EXPOSE 3000
CMD [ "node", "app.js" ]