FROM python:3.12-slim

RUN useradd --system --no-create-home --uid 10001 notifier
WORKDIR /app
COPY notifier.py /app/notifier.py

USER notifier
ENV PYTHONUNBUFFERED=1
CMD ["python", "/app/notifier.py"]
