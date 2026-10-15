FROM python:3.12.13-slim-trixie

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Test dependencies
RUN pip install --no-cache-dir pytest httpx

RUN mkdir -p /var/lib/phantom/auth

EXPOSE 8443

CMD ["python", "-m", "auth_service"]
