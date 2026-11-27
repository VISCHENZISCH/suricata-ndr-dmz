import os
import hmac
import hashlib
import secrets
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

# Sessions memory : {token: {"email": ..., "username": ...}}
SESSIONS: dict[str, dict] = {}

# Parametres scrypt : n=2^14 impose 16 Mio de memoire par calcul, soit ~50 ms
# ici. C'est ce cout memoire qui rend une attaque GPU ou ASIC non rentable,
# contrairement a un simple SHA-256.
SCRYPT_N = 2 ** 14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 32


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def hash_password(password: str) -> str:
    """Derive un mot de passe avec scrypt (memoire dure, resiste au GPU).

    Format : scrypt$n$r$p$sel$empreinte. Les parametres sont stockes dans
    l'empreinte pour pouvoir les durcir plus tard sans casser les comptes.
    """
    salt = secrets.token_hex(16)
    dk = hashlib.scrypt(
        password.encode(),
        salt=salt.encode(),
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
        dklen=SCRYPT_DKLEN,
    )
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${salt}${dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    """Verifie un mot de passe, y compris l'ancien format sha256 (migration)."""
    parts = stored.split("$")
    if parts[0] == "scrypt" and len(parts) == 6:
        _, n, r, p, salt, expected = parts
        dk = hashlib.scrypt(
            password.encode(),
            salt=salt.encode(),
            n=int(n),
            r=int(r),
            p=int(p),
            dklen=len(expected) // 2,
        )
        return hmac.compare_digest(dk.hex(), expected)
    if len(parts) == 2:  # ancien format : sel$sha256
        salt, h = parts
        legacy = hashlib.sha256(f"{salt}{password}".encode()).hexdigest()
        return hmac.compare_digest(legacy, h)
    return False


def needs_rehash(stored: str) -> bool:
    """Vrai si l'empreinte n'est pas au format scrypt courant."""
    return not stored.startswith(f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}$")


# Check Health
@app.get("/api/health")
def health(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok", "db": "up"}


# Whoami
@app.get("/api/me")
def me(request: Request):
    token = request.cookies.get("session")
    if not token or token not in SESSIONS:
        raise HTTPException(401, "Non connecté")
    return SESSIONS[token]


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

    # Migration transparente : un compte encore en sha256 est re-hache en scrypt
    # des la premiere connexion reussie, sans demander de changer de mot de passe.
    if needs_rehash(row[0]):
        db.execute(
            text("UPDATE users SET password_hash = :h WHERE email = :e"),
            {"h": hash_password(password), "e": email},
        )
        db.commit()

    token = secrets.token_hex(32)
    SESSIONS[token] = {"email": email, "username": row[1]}

    redirect = RedirectResponse(url="/dashboard.html", status_code=303)
    redirect.set_cookie(
        key="session",
        value=token,
        httponly=True,
        samesite="lax",
        max_age=86400,  # 24 h
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