import os, subprocess as s, pathlib as P, time, json, re, hashlib
root=P.Path.cwd(); scratch=root/'.ntfy-validation'; ev=P.Path('/home/awilliam/.no-mistakes/evidence/01M2APVF6KH0MTJCKPDH05D7SK')
ntfy=str(scratch/'ntfy_2.28.0_linux_amd64/ntfy'); cfg=str(scratch/'server.yml')
env=dict(os.environ, NTFY_CONFIG_FILE=cfg, TMPDIR=str(scratch/'tmp'), CURL_CA_BUNDLE=str(scratch/'cert.pem'))
log=[]; server=None

def start():
 global server
 server=s.Popen([ntfy,'serve'],env=env,stdout=open(scratch/'server.log','a'),stderr=s.STDOUT)
 for _ in range(100):
  p=s.run(['curl','-fsS','https://localhost:19443/v1/health'],env=env,capture_output=True)
  if p.returncode==0: return
  time.sleep(.1)
 raise RuntimeError((scratch/'server.log').read_text())
def stop():
 global server
 if server: server.terminate(); server.wait(timeout=10); server=None

def cmd(home,*args,extra=None,rc=0):
 e=dict(env,FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_ROOT_OVERRIDE=str(root))
 if extra: e.update(extra)
 p=s.run(args,env=e,text=True,capture_output=True)
 log.append({'command':list(args),'home':home.name,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 assert p.returncode==rc,(args,p.stdout,p.stderr,p.returncode)
 return p.stdout+p.stderr

def cli(home,action,**kw): return cmd(home,str(root/'bin/fm-ntfy.sh'),action,**kw)
def records(home,kind): return list((home/'state/ntfy'/kind).glob('*.rec'))
def project(home,text):
 f=home/'state/task.status'
 with f.open('a') as o:o.write(text+'\n')
 cmd(home,'bash','-c','. "$1"; signal_files_actionable "$2/state/task.status"; fm_wake_status_mark_current "$2/state" "$2/state/task.status"','_',str(root/'bin/fm-watch.sh'),str(home))
def record(home,kind,scope,link=''):
 cmd(home,'bash','-c','. "$1"; fm_ntfy_record "$2" "$3" "$4"','_',str(root/'bin/fm-ntfy-lib.sh'),kind,scope,link)
def poll():
 p=s.run(['curl','-fsS','-H','@'+str(scratch/'auth-header'),'https://localhost:19443/isolated-validation/json?poll=1&since=all'],env=env,text=True,capture_output=True)
 assert p.returncode==0,p.stderr
 return [json.loads(x) for x in p.stdout.splitlines() if x]
def configure(home,extra=''):
 home.mkdir(exist_ok=True);(home/'state').mkdir(exist_ok=True)
 (home/'.env').write_text(f'FM_NTFY_URL=https://localhost:19443\nFM_NTFY_TOPIC=isolated-validation\nFM_NTFY_TOKEN_FILE={scratch}/token\n'+extra)
try:
 start();stop()
 s.run([ntfy,'user','add','--role=admin','validation'],env=dict(env,NTFY_PASSWORD='isolated-test-password'),check=True,capture_output=True)
 p=s.run([ntfy,'token','add','validation'],env=env,check=True,text=True,capture_output=True)
 token=re.search(r'tk_[a-zA-Z0-9]+',p.stdout)[0]
 (scratch/'token').write_text(token+'\n');(scratch/'token').chmod(0o600)
 (scratch/'auth-header').write_text('Authorization: Bearer '+token+'\n');(scratch/'auth-header').chmod(0o600)
 start()
 a=scratch/'home-a';b=scratch/'home-b';configure(a);b.mkdir();(b/'state').mkdir()
 assert 'off' in cli(b,'status',extra={'FM_NTFY_URL':'https://localhost:19443','FM_NTFY_TOPIC':'isolated-validation','FM_NTFY_TOKEN_FILE':str(scratch/'token')})
 cli(b,'check');record(b,'decision-required','private-b');assert not (b/'state/ntfy').exists();assert poll()==[]
 original=(a/'.env').read_text()
 for bad in [original.replace('https://localhost','http://localhost'),original+'FM_NTFY_TOKEN=inline-forbidden\n']:
  (a/'.env').write_text(bad);assert 'misconfigured' in cli(a,'status',rc=1)
 (a/'.env').write_text(original);(scratch/'token').chmod(0o644);assert 'misconfigured' in cli(a,'status',rc=1);(scratch/'token').chmod(0o600)
 assert poll()==[]
 assert 'Accepted is not delivered and not read' in cli(a,'test');assert len(poll())==1;assert not records(a,'outbox') and not records(a,'receipts')
 cli(a,'arm');assert 'armed=yes' in cli(a,'status')
 project(a,'done: checks complete ; failed: 0 ; blocked: 0');assert not records(a,'outbox')
 project(a,'needs-decision [key=k]: SECRET-WORKER-PROSE');assert len(records(a,'outbox'))==1
 source=(a/'state/task.status').read_bytes();(ev/'live-intent.txt').write_text(records(a,'outbox')[0].read_text())
 cmd(a,str(a/'state/ntfy.check.sh'));assert (a/'state/task.status').read_bytes()==source
 assert len(records(a,'receipts'))==1 and not records(a,'outbox');assert len(poll())==2
 cli(a,'check');assert len(poll())==2
 project(a,'captain-held [key=k]: SECRET-WORKER-PROSE');cli(a,'check');assert len(poll())==2
 project(a,'resolved [key=k]: answer\nneeds-decision [key=k]: new SECRET-WORKER-PROSE');cli(a,'check');assert len(poll())==3
 configure(a,'FM_NTFY_PR_LINKS=on\n')
 record(a,'pr-ready','private-client','https://github.com/example/project/pull/123');cli(a,'check')
 record(a,'pr-ready','private-client-2','https://evil.example/action');cli(a,'check')
 messages=poll();assert len(messages)==5
 assert messages[3]['actions'][0]['action']=='view'; assert 'actions' not in messages[4]
 assert all('SECRET-WORKER' not in json.dumps(m) and 'private-client' not in json.dumps(m) and token not in json.dumps(m) for m in messages)
 (ev/'live-messages.json').write_text(json.dumps(messages,indent=2))
 record(a,'work-failed','budget')
 assert 'cannot accommodate' in cli(a,'check',extra={'FM_CHECK_TIMEOUT':'1'})
 assert cli(a,'check',extra={'FM_CHECK_TIMEOUT':'1'})==''
 assert len(records(a,'outbox'))==1
 stop();t=time.monotonic();cli(a,'check',extra={'FM_CHECK_TIMEOUT':'5'});assert time.monotonic()-t<5
 pending=records(a,'outbox')[0];assert 'attempts=1' in pending.read_text();(ev/'live-outage-intent.txt').write_text(pending.read_text())
 start();time.sleep(38);cli(a,'check');assert not records(a,'outbox')
 before=len(poll());stop();start();cli(a,'check');assert len(poll())==before
 record(a,'credential-required','revoked')
 (scratch/'token').write_text('tk_'+'a'*29+'\n')
 out=cli(a,'check');assert 'refused' in out
 assert cli(a,'check')=='' and len(records(a,'outbox'))==1
 (scratch/'token').write_text(token+'\n')
 cli(a,'disarm');assert 'armed=no' in cli(a,'status');assert len(records(a,'outbox'))==1
 (ev/'live-receipts.txt').write_text('\n'.join(f.read_text() for f in records(a,'receipts')))
 log.append({'result':'all live assertions passed','ntfy_version':'2.28.0'})
finally:
 stop();(ev/'live-cli-transcript.json').write_text(json.dumps(log,indent=2))
