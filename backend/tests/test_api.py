import os
import time
import uuid
import pytest
from fastapi.testclient import TestClient
import app as api

@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(api, 'DB_PATH', str(tmp_path / 'test.sqlite3'))
    api.init_db()
    return TestClient(api.app)

def session(uid=None, old=False):
    uid = uid or str(uuid.uuid4())
    token = str(uuid.uuid4())
    with api.db() as c:
        c.execute('INSERT INTO users(id,created) VALUES (?,?)', (uid, time.time()))
        c.execute('INSERT INTO sessions VALUES (?,?,?,?)', (api.digest(token), uid, time.time()+3600, time.time()-(1000 if old else 0)))
    return uid, {'Authorization': 'Bearer '+token}

def record(day='2026-01-01'):
    return {'id':str(uuid.uuid4()),'day':day,'kind':'yellow','size':'M','createdAt':700000000,'updatedAt':700000000}

def test_anonymous_cannot_access_records(client):
    assert client.get('/v1/checkins').status_code == 401

def test_snapshot_persistence_and_isolation(client):
    _, a = session(); _, b = session()
    value = record()
    result=client.put('/v1/checkins',headers=a,json={'revision':0,'records':[value]})
    assert result.status_code == 200
    assert result.json()['revision'] == 1
    assert client.get('/v1/checkins',headers=a).json()['records'][0]['day'] == value['day']
    assert client.get('/v1/checkins',headers=b).json()['records'] == []

def test_stale_revision_cannot_overwrite(client):
    _, h = session()
    client.put('/v1/checkins',headers=h,json={'revision':0,'records':[record()]})
    assert client.put('/v1/checkins',headers=h,json={'revision':0,'records':[]}).status_code == 409
    assert len(client.get('/v1/checkins',headers=h).json()['records']) == 1

def test_deleted_records_stay_deleted(client):
    _, h = session()
    client.put('/v1/checkins',headers=h,json={'revision':0,'records':[record()]})
    assert client.put('/v1/checkins',headers=h,json={'revision':1,'records':[]}).status_code == 200
    assert client.get('/v1/checkins',headers=h).json() == {'revision':2,'records':[]}

@pytest.mark.parametrize('values',[[record('2026-02-30')],[record('2999-01-01')],[record(),record()]])
def test_invalid_dates_and_duplicates(client,values):
    _, h = session()
    assert client.put('/v1/checkins',headers=h,json={'revision':0,'records':values}).status_code == 422

def test_logout_revokes_session(client):
    _, h = session()
    assert client.post('/v1/auth/logout',headers=h).status_code == 200
    assert client.get('/v1/checkins',headers=h).status_code == 401

def test_delete_requires_recent_login(client):
    _, h = session(old=True)
    assert client.delete('/v1/account',headers=h).status_code == 401

def test_delete_cascades_and_revokes(client):
    uid, h = session()
    client.put('/v1/checkins',headers=h,json={'revision':0,'records':[record()]})
    assert client.delete('/v1/account',headers=h).status_code == 200
    assert client.get('/v1/checkins',headers=h).status_code == 401
    with api.db() as c:
        assert c.execute('SELECT count(*) FROM checkins').fetchone()[0] == 0

def test_challenge_is_single_use(client,monkeypatch):
    monkeypatch.setattr(api,'verify_provider',lambda p,b,n: ('test-sub',''))
    challenge=client.post('/v1/auth/challenge').json()
    body={'challenge_id':challenge['id'],'code':'test'}
    assert client.post('/v1/auth/login/apple',json=body).status_code == 200
    assert client.post('/v1/auth/login/apple',json=body).status_code == 401

def test_account_link_never_merges_other_user(client,monkeypatch):
    uid, h = session(); other, _ = session()
    with api.db() as c:
        c.execute('INSERT INTO identities VALUES (?,?,?,?)',('wechat','taken',other,''))
    monkeypatch.setattr(api,'verify_provider',lambda p,b,n: ('taken',''))
    challenge=client.post('/v1/auth/challenge').json()
    assert client.post('/v1/account/link/wechat',headers=h,json={'challenge_id':challenge['id'],'code':'test'}).status_code == 409

def test_unconfigured_login_not_fake_success(client,monkeypatch):
    monkeypatch.delenv('APPLE_CLIENT_ID',raising=False)
    challenge=client.post('/v1/auth/challenge').json()
    assert client.post('/v1/auth/login/apple',json={'challenge_id':challenge['id'],'code':'x'}).status_code == 503

@pytest.mark.parametrize('aud,nonce,sub,expected',[
    ('com.test.poopals','correct','user-1',True),
    ('other-app','correct','user-1',False),
    ('com.test.poopals','wrong','user-1',False),
    ('com.test.poopals','correct','different-user',False),
])
def test_apple_signature_audience_nonce_and_code_binding(client,monkeypatch,aud,nonce,sub,expected):
    from cryptography.hazmat.primitives.asymmetric import rsa
    from types import SimpleNamespace
    from fastapi import HTTPException
    private=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    claims={'iss':'https://appleid.apple.com','aud':aud,'sub':'user-1','iat':int(time.time()),'exp':int(time.time())+60,'nonce':api.digest(nonce)}
    token=api.jwt.encode(claims,private,algorithm='RS256',headers={'kid':'test'})
    exchange=api.jwt.encode({**claims,'aud':'com.test.poopals','sub':sub},private,algorithm='RS256',headers={'kid':'test'})
    monkeypatch.setenv('APPLE_CLIENT_ID','com.test.poopals')
    monkeypatch.setattr(api,'configured',lambda provider:True)
    monkeypatch.setattr(api,'apple_secret',lambda:'test-client-secret')
    monkeypatch.setattr(api.jwt,'PyJWKClient',lambda url:SimpleNamespace(get_signing_key_from_jwt=lambda value:SimpleNamespace(key=private.public_key())))
    class FakeClient:
        def __init__(self,**kwargs):pass
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def post(self,*args,**kwargs):return SimpleNamespace(raise_for_status=lambda:None,json=lambda:{'id_token':exchange,'refresh_token':'refresh'})
    monkeypatch.setattr(api.httpx,'Client',FakeClient)
    body=api.Login(challenge_id='test',code='one-time-code',identity_token=token)
    if expected:
        assert api.verify_provider('apple',body,'correct') == ('user-1','refresh')
    else:
        with pytest.raises(HTTPException) as error:api.verify_provider('apple',body,'correct')
        assert error.value.status_code == 401
