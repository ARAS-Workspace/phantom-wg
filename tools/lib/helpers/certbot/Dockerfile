FROM python:3.12-alpine
RUN apk add --no-cache certbot
COPY certbot_obtain.py /app/certbot_obtain.py
ENTRYPOINT ["python3", "/app/certbot_obtain.py"]