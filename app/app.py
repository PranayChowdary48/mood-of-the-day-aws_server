import datetime
import json
import logging
import os
import random
import socket
import threading
import time
from typing import Any, Dict, Optional, Tuple

import redis
from flask import Flask, Response, g, jsonify, render_template, request
from prometheus_client import Counter, Gauge, Histogram, generate_latest
from pythonjsonlogger import jsonlogger

try:
    import boto3
except Exception:  # pragma: no cover
    boto3 = None

try:
    import psycopg2
except Exception:  # pragma: no cover
    psycopg2 = None

app = Flask(__name__)

logger = logging.getLogger()
logger.setLevel(logging.INFO)
log_handler = logging.StreamHandler()
log_handler.setFormatter(
    jsonlogger.JsonFormatter("%(asctime)s %(levelname)s %(message)s %(container)s %(request_path)s")
)
logger.handlers = [log_handler]

REQUEST_COUNT = Counter("http_requests_total", "Total HTTP requests", ["method", "path", "status"])
REQUEST_LATENCY = Histogram("http_request_latency_seconds", "Request latency", ["path", "method"])
ACTIVE_REQUESTS = Gauge("http_requests_in_flight", "In-flight HTTP requests")

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

ASSET_BASE_URL = os.getenv("ASSET_BASE_URL", "").rstrip("/")
SQS_ASYNC_REFRESH = os.getenv("SQS_ASYNC_REFRESH", "false").lower() == "true"
SQS_WORKER_ENABLED = os.getenv("SQS_WORKER_ENABLED", "false").lower() == "true"
QUEUE_URL = os.getenv("QUEUE_URL", "")
AWS_REGION = os.getenv("AWS_REGION", os.getenv("AWS_DEFAULT_REGION", "us-east-1"))
KINESIS_ENABLED = os.getenv("KINESIS_ENABLED", "false").lower() == "true"
KINESIS_STREAM_NAME = os.getenv("KINESIS_STREAM_NAME", "")
SHARED_DATA_PATH = os.getenv("SHARED_DATA_PATH", "/mnt/shared")

DB_HOST = os.getenv("DB_HOST", "")
DB_PORT = int(os.getenv("DB_PORT", "5432")) if os.getenv("DB_PORT") else 5432
DB_NAME = os.getenv("DB_NAME", "mood")
DB_USER = os.getenv("DB_USER", "moodapp")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

MOOD_FILES = {
    "Happy": "happy.gif",
    "Sad": "sad.gif",
    "Angry": "angry.gif",
    "Tired": "tired.gif",
    "Hungry": "hungry.gif",
    "Proud": "proud.gif",
    "Love": "love.gif",
}

MOOD_FALLBACK = {
    "Happy": "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExY2FubWFtNDhxbDNsOTV6Z2ExbXdtYTdrZm9hOHd2bG44NjQ1eW5ldCZlcD12MV9naWZzX3NlYXJjaCZjdD1n/fUQ4rhUZJYiQsas6WD/giphy.gif",
    "Sad": "https://media.giphy.com/media/v1.Y2lkPWVjZjA1ZTQ3NDF2cGVuZWs1bnVkNTVqdTFmYjdqamo4Ynd0bjVocHoxYjNoZWt5ayZlcD12MV9naWZzX3NlYXJjaCZjdD1n/2rtQMJvhzOnRe/giphy.gif",
    "Angry": "https://media.giphy.com/media/v1.Y2lkPWVjZjA1ZTQ3Nzh3ZWIxbnJianduaGhtbzl1ZGwxYnd3Y2E1eDV4ZDgxcmMzZWY3YSZlcD12MV9naWZzX3NlYXJjaCZjdD1n/29bKyyjDKX1W8/giphy.gif",
    "Tired": "https://media2.giphy.com/media/v1.Y2lkPTc5MGI3NjExbGxpZzEwaXBzdjA1ZzN5dnFzdmZrem02ZzdpMXdudDR4Ynk3NXJqMCZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/Zsc4dATQgcBmU/giphy.gif",
    "Hungry": "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExcWF4ZXU3MmdidzZwZDF2bXRsZmRoNjFtbWV0YzdmYzF2YXIzOXZtNiZlcD12MV9naWZzX3NlYXJjaCZjdD1n/jKaFXbKyZFja0/giphy.gif",
    "Proud": "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExNDdhNXQyNXAxZm84ajI5eTNvNDR6YWR6Mnl0bDlndHFqc2t0MW95ciZlcD12MV9naWZzX3NlYXJjaCZjdD1n/Vg2TAoPzDstzy/giphy.gif",
    "Love": "https://media.giphy.com/media/v1.Y2lkPWVjZjA1ZTQ3aTFyanZnNHg5NWprN2EzM3o2YjNzbmdlZG8zYm1iOWdjYzN4NGNhaiZlcD12MV9naWZzX3NlYXJjaCZjdD1n/XtluHogie3wB2/giphy.gif",
}


def _build_mood_assets() -> Dict[str, str]:
    if ASSET_BASE_URL:
        return {mood: f"{ASSET_BASE_URL}/gifs/{fname}" for mood, fname in MOOD_FILES.items()}
    return MOOD_FALLBACK


MOODS = _build_mood_assets()

redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

sqs_client = None
if QUEUE_URL and boto3 is not None:
    sqs_client = boto3.client("sqs", region_name=AWS_REGION)

kinesis_client = None
if KINESIS_ENABLED and KINESIS_STREAM_NAME and boto3 is not None:
    kinesis_client = boto3.client("kinesis", region_name=AWS_REGION)

_db_schema_initialized = False
_db_schema_lock = threading.Lock()


def db_enabled() -> bool:
    return bool(DB_HOST and DB_PASSWORD and psycopg2 is not None)


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    )


def ensure_db_schema() -> None:
    global _db_schema_initialized
    if not db_enabled() or _db_schema_initialized:
        return
    with _db_schema_lock:
        if _db_schema_initialized:
            return
        conn = get_db_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS mood_history (
                      id BIGSERIAL PRIMARY KEY,
                      day DATE NOT NULL,
                      mood TEXT NOT NULL,
                      gif TEXT NOT NULL,
                      generated_at TIMESTAMP NOT NULL,
                      source TEXT NOT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT NOW()
                    )
                    """
                )
            conn.commit()
            _db_schema_initialized = True
        finally:
            conn.close()


def persist_mood(day_iso: str, mood: str, gif: str, generated_at: str, source: str) -> None:
    if not db_enabled():
        return
    try:
        ensure_db_schema()
        conn = get_db_connection()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO mood_history(day, mood, gif, generated_at, source)
                    VALUES (%s, %s, %s, %s, %s)
                    """,
                    (day_iso, mood, gif, generated_at, source),
                )
            conn.commit()
        finally:
            conn.close()
    except Exception as exc:  # pragma: no cover
        logger.error("db_write_failed", extra={"error": str(exc)})


def require_basic_auth() -> bool:
    user = os.getenv("REFRESH_USER")
    password = os.getenv("REFRESH_PASSWORD")
    if not user or not password:
        return False
    auth = request.authorization
    if not auth:
        return False
    return auth.username == user and auth.password == password


def publish_kinesis_event(event_type: str, payload: Dict[str, Any]) -> None:
    if not kinesis_client or not KINESIS_STREAM_NAME:
        return
    try:
        event = {
            "event_type": event_type,
            "generated_at": datetime.datetime.utcnow().isoformat(),
            "payload": payload,
        }
        partition_key = payload.get("mood", "mood")
        kinesis_client.put_record(
            StreamName=KINESIS_STREAM_NAME,
            Data=json.dumps(event).encode("utf-8"),
            PartitionKey=str(partition_key),
        )
    except Exception as exc:  # pragma: no cover
        logger.error("kinesis_publish_failed", extra={"error": str(exc)})


def _shared_file_path(filename: str) -> str:
    safe = filename.replace("..", "").replace("/", "")
    return os.path.join(SHARED_DATA_PATH, safe)


@app.before_request
def start_timer() -> None:
    g.start_time = time.perf_counter()
    ACTIVE_REQUESTS.inc()


@app.after_request
def record_metrics(response):
    REQUEST_COUNT.labels(request.method, request.path, response.status_code).inc()
    if hasattr(g, "start_time"):
        REQUEST_LATENCY.labels(request.path, request.method).observe(time.perf_counter() - g.start_time)
    ACTIVE_REQUESTS.dec()
    return response


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype="text/plain")


def seconds_until_midnight() -> int:
    now = datetime.datetime.now()
    tomorrow = now + datetime.timedelta(days=1)
    midnight = datetime.datetime.combine(tomorrow.date(), datetime.time.min)
    return int((midnight - now).total_seconds())


def today_key() -> Tuple[str, str]:
    day = datetime.date.today().isoformat()
    return day, f"mood:{day}"


def get_or_generate_mood(force_refresh: bool = False, source: str = "api") -> Dict[str, Any]:
    day, redis_key = today_key()
    hostname = socket.gethostname()

    cached: Dict[str, str] = {}
    if not force_refresh:
        cached = redis_client.hgetall(redis_key)

    if cached:
        mood = cached["mood"]
        gif = cached["gif"]
        generated_at = cached["generated_at"]
        cache_status = "HIT"
    else:
        mood, gif = random.choice(list(MOODS.items()))
        generated_at = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        redis_client.hset(redis_key, mapping={"mood": mood, "gif": gif, "generated_at": generated_at})
        redis_client.expire(redis_key, seconds_until_midnight())
        cache_status = "MISS"
        persist_mood(day, mood, gif, generated_at, source)

    logger.info(
        "mood_generated",
        extra={
            "container": hostname,
            "request_path": request.path if request else "worker",
            "redis_key": redis_key,
            "cache_status": cache_status,
            "mood": mood,
            "source": source,
        },
    )

    publish_kinesis_event(
        "mood.generated",
        {
            "hostname": hostname,
            "redis_key": redis_key,
            "cache_status": cache_status,
            "mood": mood,
            "source": source,
        },
    )

    return {
        "mood": mood,
        "gif": gif,
        "generated_at": generated_at,
        "hostname": hostname,
        "cache_status": cache_status,
    }


def enqueue_refresh() -> bool:
    if not sqs_client or not QUEUE_URL:
        return False
    sqs_client.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps({"action": "refresh", "requested_at": datetime.datetime.utcnow().isoformat()}),
    )
    return True


def sqs_worker_loop() -> None:
    if not sqs_client or not QUEUE_URL:
        return
    logger.info("sqs_worker_started", extra={"queue_url": QUEUE_URL})
    while True:
        try:
            resp = sqs_client.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=10,
                VisibilityTimeout=30,
            )
            msgs = resp.get("Messages", [])
            if not msgs:
                continue
            for msg in msgs:
                receipt = msg.get("ReceiptHandle")
                body_raw = msg.get("Body", "{}")
                body = json.loads(body_raw)
                if body.get("force_fail"):
                    raise RuntimeError("forced failure for DLQ test")
                get_or_generate_mood(force_refresh=True, source="sqs")
                sqs_client.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt)
        except Exception as exc:  # pragma: no cover
            logger.error("sqs_worker_error", extra={"error": str(exc)})
            time.sleep(2)


@app.route("/")
def mood_of_the_day():
    data = get_or_generate_mood(force_refresh=False, source="web")
    return render_template(
        "index.html",
        mood=data["mood"],
        gif=data["gif"],
        generated_at=data["generated_at"],
        hostname=data["hostname"],
    )


@app.route("/api/mood")
def api_mood():
    return jsonify(get_or_generate_mood(force_refresh=False, source="api"))


@app.route("/refresh", methods=["POST"])
@app.route("/api/refresh", methods=["POST"])
def refresh_mood():
    if not require_basic_auth():
        return Response("Unauthorized", 401, {"WWW-Authenticate": 'Basic realm="mood"'})

    if SQS_ASYNC_REFRESH and sqs_client and QUEUE_URL:
        enqueue_refresh()
        return jsonify({"status": "accepted", "mode": "async", "queue_url": QUEUE_URL}), 202

    return jsonify(get_or_generate_mood(force_refresh=True, source="sync-refresh"))


@app.route("/api/shared/read")
def shared_read():
    filename = request.args.get("file", "probe.txt")
    path = _shared_file_path(filename)
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        return jsonify({"file": filename, "path": path, "content": content, "hostname": socket.gethostname()}), 200
    except FileNotFoundError:
        return jsonify({"error": "file_not_found", "file": filename, "path": path, "hostname": socket.gethostname()}), 404
    except Exception as exc:
        return jsonify({"error": str(exc), "file": filename, "path": path, "hostname": socket.gethostname()}), 500


@app.route("/api/shared/write", methods=["POST"])
def shared_write():
    filename = request.args.get("file", "probe.txt")
    payload = request.get_json(silent=True) or {}
    content = payload.get("content") or f"written-by={socket.gethostname()} at {datetime.datetime.utcnow().isoformat()}"
    path = _shared_file_path(filename)
    try:
        os.makedirs(SHARED_DATA_PATH, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return jsonify({"file": filename, "path": path, "content": content, "hostname": socket.gethostname()}), 200
    except Exception as exc:
        return jsonify({"error": str(exc), "file": filename, "path": path, "hostname": socket.gethostname()}), 500


@app.route("/whoami")
def whoami():
    return socket.gethostname()


@app.route("/health")
def health():
    try:
        redis_client.ping()
        if db_enabled():
            conn = get_db_connection()
            try:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
                    cur.fetchone()
            finally:
                conn.close()
        return {"status": "ready"}, 200
    except Exception:
        return {"status": "not_ready"}, 503


@app.route("/live")
def live():
    return {"status": "ok"}, 200


if SQS_WORKER_ENABLED and sqs_client and QUEUE_URL:
    worker_thread = threading.Thread(target=sqs_worker_loop, daemon=True)
    worker_thread.start()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
