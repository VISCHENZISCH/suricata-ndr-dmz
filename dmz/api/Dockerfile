FROM python:3.12-slim

WORKDIR /srv
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

COPY requirements.txt .
# --retries/--timeout : les reseaux de campus coupent regulierement les
# connexions vers PyPI, ce qui fait echouer la construction pour rien.
RUN pip install --no-cache-dir --retries 10 --timeout 60 -r requirements.txt

COPY app ./app

RUN useradd -r -u 10001 apiuser
USER apiuser

EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/health')" || exit 1
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
