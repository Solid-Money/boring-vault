FROM node:20-alpine

WORKDIR /app

# Copy package files first for better caching
COPY package*.json ./

# Install dependencies
RUN npm ci

# Copy only required files
COPY scripts/ scripts/

# Set environment variables
ENV NODE_ENV=production
