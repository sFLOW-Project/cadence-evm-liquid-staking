# Build TypeScript, then run with production deps only.
FROM node:22-alpine AS builder

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY db ./db/
COPY *.ts ./
RUN npm run build

FROM node:22-alpine AS runner

WORKDIR /app
ENV NODE_ENV=production

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY --from=builder /app/dist ./dist

USER node
CMD ["node", "dist/index.js"]
