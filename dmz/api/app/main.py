import os
import hashlib
import hmac
import secrets
import time
from contextlib import asynccontextmanager
from fastapi import FastAPI, Depends, Form, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from sqlalchemy import create_engine, text, URL
from sqlalchemy.orm import Session, sessionmaker

DATABASE_URL = URL.create(
    drivername="postgresql+psycopg",
    username=os.getenv("POSTGRES_USER"),
    password=os.getenv("POSTGRES_PASSWORD"),
    host=os.getenv("POSTGRES_HOST", "db"),
    port=5432,
    database=os.getenv("POSTGRES_DB"),
)

engine = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False)

@asynccontextmanager
async def lifespan(_app: FastAPI):
    bcyan = "\033[1;96m"
    dim = "\033[2m"
    reset = "\033[0m"
    banner = (
        "\n\n"
        f"{bcyan}"
        "                  d8b \n"
        "                  Y8P \n"
        "                      \n"
        " 8888b.  88888b.  888 \n"
        '    "88b 888 "88b 888 \n'
        ".d888888 888  888 888 \n"
        "888  888 888 d88P 888 \n"
        '"Y888888 88888P"  888 \n'
        "         888          \n"
        "         888          \n"
        "         888          \n"
        f"{reset}  {dim}Groupe 2 · API FastAPI DMZ (PostgreSQL){reset}\n\n\n"
    )
    print(banner, flush=True)
    yield


app = FastAPI(title="G2 API", lifespan=lifespan)

origins = os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
    allow_credentials=True,
)

# Sessions memory : {token: {"email": ..., "username": ..., "expires_at": ...}}
SESSION_TTL = 86400
MAX_SESSIONS = 1000
SESSIONS: dict[str, dict] = {}


def _prune_sessions(now: float) -> None:
    """Supprime les sessions expirées et borne le cache en mémoire."""
    expired = [k for k, v in SESSIONS.items() if v["expires_at"] <= now]
    for k in expired:
        del SESSIONS[k]
    while len(SESSIONS) >= MAX_SESSIONS:
        oldest = min(SESSIONS, key=lambda k: SESSIONS[k]["expires_at"])
        del SESSIONS[oldest]


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    h = hashlib.sha256(f"{salt}{password}".encode()).hexdigest()
    return f"{salt}${h}"


def verify_password(password: str, stored: str) -> bool:
    if "$" not in stored:
        return False
    salt, h = stored.split("$", 1)
    candidate = hashlib.sha256(f"{salt}{password}".encode()).hexdigest()
    return hmac.compare_digest(candidate, h)


# Check Health
@app.get("/api/health")
def health(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok", "db": "up"}


# Whoami
@app.get("/api/me")
def me(request: Request):
    token = request.cookies.get("session")
    session = SESSIONS.get(token) if token else None
    if not session or session["expires_at"] <= time.time():
        if token and token in SESSIONS:
            del SESSIONS[token]
        raise HTTPException(401, "Non connecté")
    return {"email": session["email"], "username": session["username"]}


# Register
@app.post("/api/register")
def register(
    email: str = Form(...),
    password: str = Form(...),
    password_confirm: str = Form(...),
    db: Session = Depends(get_db),
):
    if password != password_confirm:
        raise HTTPException(400, "Les mots de passe ne correspondent pas.")
    if len(password) < 8:
        raise HTTPException(400, "Le mot de passe doit contenir au moins 8 caractères.")

    exists = db.execute(
        text("SELECT 1 FROM users WHERE email = :e"), {"e": email}
    ).fetchone()
    if exists:
        raise HTTPException(409, "Un compte avec cet e-mail existe déjà.")

    pw_hash = hash_password(password)
    db.execute(
        text(
            "INSERT INTO users (email, username, password_hash) "
            "VALUES (:email, :username, :pw)"
        ),
        {"email": email, "username": email.split("@")[0], "pw": pw_hash},
    )
    db.commit()
    return RedirectResponse(url="/login.html", status_code=303)


# Login
@app.post("/api/login")
def login(
    response: Response,
    email: str = Form(...),
    password: str = Form(...),
    db: Session = Depends(get_db),
):
    row = db.execute(
        text("SELECT password_hash, username FROM users WHERE email = :e"),
        {"e": email},
    ).fetchone()
    if not row or not verify_password(password, row[0]):
        raise HTTPException(401, "E-mail ou mot de passe incorrect.")

    now = time.time()
    _prune_sessions(now)
    token = secrets.token_hex(32)
    SESSIONS[token] = {"email": email, "username": row[1], "expires_at": now + SESSION_TTL}

    redirect = RedirectResponse(url="/dashboard.html", status_code=303)
    redirect.set_cookie(
        key="session",
        value=token,
        httponly=True,
        samesite="lax",
        max_age=SESSION_TTL,
    )
    return redirect


# Logout
@app.post("/api/logout")
def logout(request: Request):
    token = request.cookies.get("session")
    if token and token in SESSIONS:
        del SESSIONS[token]
    redirect = RedirectResponse(url="/login.html", status_code=303)
    redirect.delete_cookie("session")
    return redirect