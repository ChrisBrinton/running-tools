FROM node:22-alpine AS build

# better-sqlite3 needs Python + build tools at install time
RUN apk add --no-cache python3 make g++

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev=false && npm cache clean --force
COPY tsconfig.json ./
COPY src ./src
RUN npx tsc

FROM node:22-alpine AS runtime
RUN apk add --no-cache tini
WORKDIR /app

# Copy only what's needed at runtime
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY package.json ./

ENV NODE_ENV=production
ENV PORT=8080
ENV PACERUNNER_DATA_DIR=/data

VOLUME ["/data"]
EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/server.js"]
