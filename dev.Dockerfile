FROM python:3.12.13-slim-trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsodium23 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Test dependencies
RUN pip install --no-cache-dir pytest httpx

RUN mkdir -p /var/lib/phantom/auth

EXPOSE 8443

CMD ["python", "-m", "auth_service"]
