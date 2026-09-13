"""
web-poc — EKS 인시던트 대응 PoC 테스트 워크로드
각 엔드포인트가 특정 시나리오의 장애를 유발한다.
"""
import os
import time
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# 시나리오 1용: /leak 호출마다 여기에 데이터 누적
_leak_store: list[bytes] = []

# 시나리오 7용: DB 커넥션 풀 시뮬레이션
DB_POOL_SIZE = int(os.getenv("DB_POOL_SIZE", "20"))
DB_HOST = os.getenv("DB_HOST", "localhost")
_active_connections = 0


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 시나리오 3: DB_HOST DNS 해석 실패는 여기서 잡힌다
    logger.info("Starting web-poc. DB_HOST=%s DB_POOL_SIZE=%s", DB_HOST, DB_POOL_SIZE)
    try:
        import socket
        socket.getaddrinfo(DB_HOST, 5432)
        logger.info("DB_HOST DNS resolution OK: %s", DB_HOST)
    except Exception as e:
        # 시나리오 3의 결정적 신호 — Agent가 previous 로그에서 이 줄을 봐야 한다
        logger.error("DB_HOST DNS resolution FAILED: %s — %s", DB_HOST, e)
    yield


app = FastAPI(title="web-poc", lifespan=lifespan)


@app.get("/healthz")
def healthz():
    """시나리오 5: readinessProbe 대상. 경로를 /health로 오기하면 probe 실패"""
    return {"status": "ok"}


@app.get("/leak")
def leak(mb: int = Query(default=10, ge=1, le=100)):
    """
    시나리오 1: 메모리 누수 유발.
    커밋으로 이 엔드포인트를 추가한 뒤 배포 → 반복 호출로 OOMKilled 유도.
    주의: 이 코드는 '누수 커밋' 이후 버전에만 존재해야 한다.
    """
    chunk = b"x" * (mb * 1024 * 1024)
    _leak_store.append(chunk)  # GC되지 않도록 전역 리스트에 보관
    logger.info("leak: allocated %dMB, total chunks=%d", mb, len(_leak_store))
    return {"allocated_mb": mb, "total_chunks": len(_leak_store)}


@app.get("/slow")
def slow(sec: int = Query(default=30, ge=1, le=120)):
    """
    시나리오 7: DB 커넥션 점유 후 대기.
    DB_POOL_SIZE를 5로 줄인 뒤 동시 호출하면 커넥션풀 고갈.
    Pod는 죽지 않고 느려진다 → Operator 감지 안 됨 (보조 경로 필요).
    """
    global _active_connections
    if _active_connections >= DB_POOL_SIZE:
        logger.warning("Connection pool exhausted (size=%d)", DB_POOL_SIZE)
        return JSONResponse(
            status_code=503,
            content={"error": "connection pool exhausted", "pool_size": DB_POOL_SIZE},
        )
    _active_connections += 1
    logger.info("Connection acquired (%d/%d), sleeping %ds", _active_connections, DB_POOL_SIZE, sec)
    try:
        time.sleep(sec)
    finally:
        _active_connections -= 1
    return {"slept_sec": sec}


@app.get("/error")
def error():
    """시나리오 7 보조: 의도적 5xx 반환 → CloudWatch 알람 트리거용"""
    logger.error("intentional 5xx error")
    return JSONResponse(status_code=500, content={"error": "intentional error"})
