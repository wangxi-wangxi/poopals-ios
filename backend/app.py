"""Poopals API. Single-instance SQLite deployment; all credentials are environment-only."""
import hashlib
import json
import os
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from datetime import date, datetime, timezone, timedelta
from typing import Literal, Optional

import httpx
import jwt
from cryptography.fernet import Fernet
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field, field_validator, model_validator

DB_PATH = os.getenv('DATABASE_PATH', 'data/poopals.sqlite3')
app = FastAPI(title='Poopals API', version='0.2.0')

@contextmanager
def db():
    os.makedirs(os.path.dirname(DB_PATH) or '.', exist_ok=True)
    c = sqlite3.connect(DB_PATH, timeout=15)
    c.row_factory = sqlite3.Row
    c.execute('PRAGMA foreign_keys=ON')
    try:
        c.execute('BEGIN IMMEDIATE')
        yield c
        c.commit()
    except Exception:
        c.rollback()
        raise
    finally:
        c.close()

def init_db():
    with db() as c:
        for sql in [
            'CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL)',
            'CREATE TABLE IF NOT EXISTS identities (provider TEXT, subject TEXT, user_id TEXT REFERENCES users(id) ON DELETE CASCADE, secret TEXT, PRIMARY KEY(provider,subject), UNIQUE(provider,user_id))',
            'CREATE TABLE IF NOT EXISTS sessions (hash TEXT PRIMARY KEY, user_id TEXT REFERENCES users(id) ON DELETE CASCADE, expires REAL, authenticated REAL)',
            'CREATE TABLE IF NOT EXISTS challenges (id TEXT PRIMARY KEY, nonce TEXT, expires REAL)',
            'CREATE TABLE IF NOT EXISTS checkins (user_id TEXT REFERENCES users(id) ON DELETE CASCADE, day TEXT, data TEXT, PRIMARY KEY(user_id,day))',
        ]:
            c.execute(sql)

init_db()

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()

def configured(provider):
    required = ['TOKEN_ENCRYPTION_KEY'] + (['APPLE_CLIENT_ID', 'APPLE_TEAM_ID', 'APPLE_KEY_ID', 'APPLE_PRIVATE_KEY'] if provider == 'apple' else ['WECHAT_APP_ID', 'WECHAT_APP_SECRET'])
    return all(os.getenv(k) for k in required)

def crypt():
    try:
        return Fernet(os.environ['TOKEN_ENCRYPTION_KEY'].encode())
    except (KeyError, ValueError):
        raise HTTPException(503, '登录服务尚未配置')

def apple_secret():
    now = int(time.time())
    return jwt.encode({'iss': os.environ['APPLE_TEAM_ID'], 'iat': now, 'exp': now + 300, 'aud': 'https://appleid.apple.com', 'sub': os.environ['APPLE_CLIENT_ID']}, os.environ['APPLE_PRIVATE_KEY'].replace('\\n', '\n'), algorithm='ES256', headers={'kid': os.environ['APPLE_KEY_ID']})

class ChallengeReply(BaseModel):
    id: str
    nonce: str

class Login(BaseModel):
    challenge_id: str = Field(max_length=100)
    code: str = Field(min_length=1, max_length=4096)
    identity_token: Optional[str] = Field(default=None, max_length=12000)
    state: Optional[str] = Field(default=None, max_length=200)

# Provider verification is kept separate so tests can inject fake provider results,
# without adding any test-login endpoint to the production server.
def verify_provider(provider: str, body: Login, nonce: str):
    if not configured(provider):
        raise HTTPException(503, '该登录渠道尚未开通')
    try:
        with httpx.Client(timeout=15) as client:
            if provider == 'apple':
                if not body.identity_token:
                    raise HTTPException(401, '缺少 Apple 凭证')
                signing_key = jwt.PyJWKClient('https://appleid.apple.com/auth/keys').get_signing_key_from_jwt(body.identity_token)
                claims = jwt.decode(body.identity_token, signing_key.key, algorithms=['RS256'], audience=os.environ['APPLE_CLIENT_ID'], issuer='https://appleid.apple.com', options={'require': ['exp', 'iat', 'sub', 'nonce']})
                if not secrets.compare_digest(claims['nonce'], digest(nonce)):
                    raise HTTPException(401, '登录验证已失效')
                response = client.post('https://appleid.apple.com/auth/token', data={'client_id': os.environ['APPLE_CLIENT_ID'], 'client_secret': apple_secret(), 'code': body.code, 'grant_type': 'authorization_code'})
                response.raise_for_status()
                tokens = response.json()
                # Validate the exchanged identity too, binding the one-use code to this user.
                exchanged = tokens.get('id_token', '')
                exchanged_key = jwt.PyJWKClient('https://appleid.apple.com/auth/keys').get_signing_key_from_jwt(exchanged)
                second = jwt.decode(exchanged, exchanged_key.key, algorithms=['RS256'], audience=os.environ['APPLE_CLIENT_ID'], issuer='https://appleid.apple.com', options={'require': ['exp', 'sub']})
                if second['sub'] != claims['sub'] or not tokens.get('refresh_token'):
                    raise HTTPException(401, 'Apple 凭证不匹配')
                return claims['sub'], tokens['refresh_token']
            if not body.state or not secrets.compare_digest(body.state, nonce):
                raise HTTPException(401, '微信登录状态不匹配')
            response = client.get('https://api.weixin.qq.com/sns/oauth2/access_token', params={'appid': os.environ['WECHAT_APP_ID'], 'secret': os.environ['WECHAT_APP_SECRET'], 'code': body.code, 'grant_type': 'authorization_code'})
            response.raise_for_status()
            tokens = response.json()
            if tokens.get('errcode') or not tokens.get('openid'):
                raise HTTPException(401, '微信授权已过期，请重试')
            # Scope subject by configured AppID; never merge by nickname or email.
            return os.environ['WECHAT_APP_ID'] + ':' + tokens['openid'], ''
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(401, '登录验证失败，请重新授权')

def current(authorization: str = Header(default='')):
    if not authorization.startswith('Bearer '):
        raise HTTPException(401, '请先登录')
    token_hash = digest(authorization[7:])
    with db() as c:
        row = c.execute('SELECT * FROM sessions WHERE hash=? AND expires>?', (token_hash, time.time())).fetchone()
    if not row:
        raise HTTPException(401, '登录已过期，请重新登录')
    return dict(row)

@app.get('/health')
def health():
    return {'status': 'ok'}

@app.get('/v1/config')
def config():
    return {'apple': configured('apple'), 'wechat': configured('wechat'), 'schema': 1}

@app.post('/v1/auth/challenge', response_model=ChallengeReply)
def challenge():
    value = {'id': str(uuid.uuid4()), 'nonce': secrets.token_urlsafe(32)}
    with db() as c:
        c.execute('DELETE FROM challenges WHERE expires<?', (time.time(),))
        if c.execute('SELECT count(*) FROM challenges').fetchone()[0] >= 10000:
            raise HTTPException(429, '请稍后再试')
        c.execute('INSERT INTO challenges VALUES (?,?,?)', (value['id'], value['nonce'], time.time() + 300))
    return value

def consume_challenge(body):
    with db() as c:
        row = c.execute('SELECT * FROM challenges WHERE id=?', (body.challenge_id,)).fetchone()
        c.execute('DELETE FROM challenges WHERE id=?', (body.challenge_id,))
    if not row or row['expires'] < time.time():
        raise HTTPException(401, '登录请求已过期，请重试')
    return row['nonce']

@app.post('/v1/auth/login/{provider}')
def login(provider: Literal['apple', 'wechat'], body: Login):
    subject, refresh = verify_provider(provider, body, consume_challenge(body))
    encrypted = crypt().encrypt(refresh.encode()).decode() if refresh else ''
    with db() as c:
        identity = c.execute('SELECT user_id FROM identities WHERE provider=? AND subject=?', (provider, subject)).fetchone()
        uid = identity['user_id'] if identity else str(uuid.uuid4())
        if not identity:
            c.execute('INSERT INTO users(id,created) VALUES (?,?)', (uid, time.time()))
            c.execute('INSERT INTO identities VALUES (?,?,?,?)', (provider, subject, uid, encrypted))
        elif refresh:
            c.execute('UPDATE identities SET secret=? WHERE provider=? AND subject=?', (encrypted, provider, subject))
        token = secrets.token_urlsafe(48)
        expires = time.time() + 30 * 86400
        c.execute('DELETE FROM sessions WHERE expires<?', (time.time(),))
        c.execute('INSERT INTO sessions VALUES (?,?,?,?)', (digest(token), uid, expires, time.time()))
    return {'user_id': uid, 'token': token, 'expires_at': expires, 'provider': provider}

@app.post('/v1/account/link/{provider}')
def link(provider: Literal['apple', 'wechat'], body: Login, session=Depends(current)):
    if time.time() - session['authenticated'] > 600:
        raise HTTPException(401, '绑定前请重新登录')
    subject, refresh = verify_provider(provider, body, consume_challenge(body))
    encrypted = crypt().encrypt(refresh.encode()).decode() if refresh else ''
    with db() as c:
        identity = c.execute('SELECT user_id FROM identities WHERE provider=? AND subject=?', (provider, subject)).fetchone()
        if identity and identity['user_id'] != session['user_id']:
            raise HTTPException(409, '该渠道已属于另一个账号，请保留两个账号并联系支持')
        same_provider = c.execute('SELECT subject FROM identities WHERE provider=? AND user_id=?', (provider, session['user_id'])).fetchone()
        if same_provider and same_provider['subject'] != subject:
            raise HTTPException(409, '已绑定该渠道的其他账号')
        c.execute('INSERT OR REPLACE INTO identities VALUES (?,?,?,?)', (provider, subject, session['user_id'], encrypted))
    return {'linked': True}

class Record(BaseModel):
    id: uuid.UUID
    day: str
    createdAt: float
    updatedAt: float
    kind: Literal['yellow', 'pink', 'green', 'purple', 'cream', 'brown']
    size: Literal['S', 'M', 'L', 'XL']

    @field_validator('day')
    @classmethod
    def valid_day(cls, value):
        parsed = date.fromisoformat(value)
        if parsed.isoformat() != value or parsed > (datetime.now(timezone.utc) + timedelta(hours=14)).date():
            raise ValueError('Invalid civil date')
        return value

    @field_validator('createdAt', 'updatedAt')
    @classmethod
    def finite_timestamp(cls, value):
        import math
        if not math.isfinite(value) or value < -978307200 or value > time.time() - 978307200 + 86400:
            raise ValueError('Invalid Apple reference timestamp')
        return value

class Snapshot(BaseModel):
    revision: int = Field(ge=0)
    records: list[Record] = Field(max_length=5000)

    @model_validator(mode='after')
    def unique_days(self):
        if len({r.day for r in self.records}) != len(self.records):
            raise ValueError('Duplicate day')
        return self

def snapshot(c, uid):
    row = c.execute('SELECT revision FROM users WHERE id=?', (uid,)).fetchone()
    if not row:
        raise HTTPException(401, '账号不存在')
    records = [json.loads(r['data']) for r in c.execute('SELECT data FROM checkins WHERE user_id=? ORDER BY day DESC', (uid,))]
    return {'revision': row['revision'], 'records': records}

@app.get('/v1/checkins')
def get_records(session=Depends(current)):
    with db() as c:
        return snapshot(c, session['user_id'])

@app.put('/v1/checkins')
def replace_records(body: Snapshot, session=Depends(current)):
    uid = session['user_id']
    with db() as c:
        current_snapshot = snapshot(c, uid)
        if current_snapshot['revision'] != body.revision:
            raise HTTPException(409, '云端有新记录，请先查看冲突再同步')
        c.execute('DELETE FROM checkins WHERE user_id=?', (uid,))
        c.executemany('INSERT INTO checkins VALUES (?,?,?)', [(uid, r.day, r.model_dump_json()) for r in body.records])
        c.execute('UPDATE users SET revision=revision+1 WHERE id=?', (uid,))
        return snapshot(c, uid)

@app.get('/v1/account')
def account(session=Depends(current)):
    with db() as c:
        providers = [r['provider'] for r in c.execute('SELECT provider FROM identities WHERE user_id=?', (session['user_id'],))]
    return {'user_id': session['user_id'], 'providers': providers}

@app.post('/v1/auth/logout')
def logout(session=Depends(current)):
    with db() as c:
        c.execute('DELETE FROM sessions WHERE hash=?', (session['hash'],))
    return {'ok': True}

@app.delete('/v1/account')
def delete_account(session=Depends(current)):
    if time.time() - session['authenticated'] > 600:
        raise HTTPException(401, '注销前请重新登录验证身份')
    with db() as c:
        identities = [dict(r) for r in c.execute('SELECT * FROM identities WHERE user_id=?', (session['user_id'],))]
    for identity in identities:
        if identity['provider'] == 'apple':
            try:
                refresh = crypt().decrypt(identity['secret'].encode()).decode()
                response = httpx.post('https://appleid.apple.com/auth/revoke', data={'client_id': os.environ['APPLE_CLIENT_ID'], 'client_secret': apple_secret(), 'token': refresh, 'token_type_hint': 'refresh_token'}, timeout=15)
                response.raise_for_status()
            except Exception:
                raise HTTPException(503, 'Apple 授权撤销暂未完成，请稍后重试；账号仍保留')
    with db() as c:
        c.execute('DELETE FROM users WHERE id=?', (session['user_id'],))
    return {'deleted': True}
