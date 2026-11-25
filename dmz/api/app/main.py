import os
import hashlib
import secrets
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

app = FastAPI(title="G2 API")

origins = os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
    allow_credentials=True,
)

# Sessions en mémoire : {token: {"email": ..., "username": ..., "role": ...}}
SESSIONS: dict[str, dict] = {}


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
    salt, h = stored.split("$", 1)
    return hashlib.sha256(f"{salt}{password}".encode()).hexdigest() == h


# ── Health ──────────────────────────────────────────────
@app.get("/api/health")
def health(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok", "db": "up"}


# ── Qui suis-je ? ──────────────────────────────────────
@app.get("/api/me")
def me(request: Request):
    token = request.cookies.get("session")
    if not token or token not in SESSIONS:
        raise HTTPException(401, "Non connecté")
    return SESSIONS[token]


# ── Inscription ─────────────────────────────────────────
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


# ── Connexion ───────────────────────────────────────────
@app.post("/api/login")
def login(
    response: Response,
    email: str = Form(...),
    password: str = Form(...),
    db: Session = Depends(get_db),
):
    row = db.execute(
        text("SELECT password_hash, username, role FROM users WHERE email = :e"),
        {"e": email},
    ).fetchone()
    if not row or not verify_password(password, row[0]):
        raise HTTPException(401, "E-mail ou mot de passe incorrect.")

    token = secrets.token_hex(32)
    SESSIONS[token] = {"email": email, "username": row[1], "role": row[2]}

    redirect = RedirectResponse(url="/dashboard.html", status_code=303)
    redirect.set_cookie(
        key="session",
        value=token,
        httponly=True,
        samesite="lax",
        max_age=86400,  # 24 h
    )
    return redirect


# ── Déconnexion ─────────────────────────────────────────
@app.post("/api/logout")
def logout(request: Request):
    token = request.cookies.get("session")
    if token and token in SESSIONS:
        del SESSIONS[token]
    redirect = RedirectResponse(url="/login.html", status_code=303)
    redirect.delete_cookie("session")
    return redirect
