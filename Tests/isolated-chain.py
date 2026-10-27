#!/usr/bin/env python3
"""Exercise a candidate chain in a disposable core without changing system routes."""
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

base = Path.home() / 'Library/Application Support/Codex Private Proxy'
original = json.loads((base / 'config.yaml').read_text())
core = base / 'mihomo'
expected_exit = os.environ.get('PRIVATE_LINE_EXPECTED_EXIT_IP')

def current_relay():
    if os.environ.get('PRIVATE_LINE_TEST_RELAY'):
        return os.environ['PRIVATE_LINE_TEST_RELAY']
    class LiveController(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(3)
            self.sock.connect(original['external-controller-unix'])
    def selected(group):
        connection = LiveController('localhost', timeout=3)
        try:
            connection.request('GET', '/proxies/' + group)
            response = connection.getresponse()
            if response.status != 200: raise RuntimeError('Live relay group unavailable')
            return json.loads(response.read()).get('now', '')
        finally:
            connection.close()
    name = selected('Wired-Relay')
    return selected('Auto-Relay') if name == 'Auto-Relay' else name

working_relay = current_relay()

with tempfile.TemporaryDirectory(prefix='private-line-test-') as tmp:
    root = Path(tmp)
    shutil.copytree(base / 'providers', root / 'providers')
    config = json.loads(json.dumps(original))
    for node in config.get('proxies', []):
        node.pop('interface-name', None)
    for name in ['lan', 'relay-lxy', 'wifi']:
        config['proxy-providers'][name].get('override', {}).pop('interface-name', None)
    config['proxy-providers']['relay-lxy'].pop('filter', None)
    config['proxy-providers']['wired-relay'].pop('filter', None)
    for provider in config['proxy-providers'].values():
        provider['type'] = 'file'
        provider.pop('url', None)
        provider.pop('proxy', None)
        provider['health-check'] = {'enable':False}
    config.setdefault('proxies', []).append({'name':'Unreachable-Relay','type':'socks5','server':'127.0.0.1','port':1})
    config['proxy-groups'] = [
        {'name':'Codex', 'type':'select', 'proxies':['Auto-Destination'], 'use':['wired-relay']},
        {'name':'Auto-Destination', 'type':'fallback', 'url':'https://www.gstatic.com/generate_204',
         'interval':0, 'use':['wired-relay']},
        {'name':'Wired-Relay', 'type':'select', 'proxies':['Auto-Relay','Unreachable-Relay'], 'use':['relay-lxy']},
        {'name':'Auto-Relay', 'type':'fallback', 'url':'https://www.gstatic.com/generate_204',
         'interval':0, 'use':['relay-lxy']},
    ]
    config['tun'] = {'enable':False}
    config['dns'] = {'enable':False}
    config.pop('external-controller', None)
    config['external-controller-unix'] = str(root / 'controller.sock')
    config['listeners'] = []
    config['rules'] = ['MATCH,Codex']
    with socket.socket() as picker:
        picker.bind(('127.0.0.1', 0))
        port = picker.getsockname()[1]
    config['mixed-port'] = port
    (root / 'config.yaml').write_text(json.dumps(config,ensure_ascii=False))
    os.chmod(root / 'config.yaml', 0o600)
    result = subprocess.run([str(core),'-t','-d',str(root),'-f',str(root/'config.yaml')],
                            capture_output=True, timeout=15)
    if result.returncode:
        raise SystemExit('candidate config rejected by Mihomo')
    class Controller(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(3)
            self.sock.connect(str(root / 'controller.sock'))
    def api(path, method='GET', payload=None):
        connection=Controller('localhost',timeout=3)
        try:
            connection.request(method,path,body=json.dumps(payload) if payload else None,
                               headers={'Authorization':'Bearer '+config['secret'],
                                        'Content-Type':'application/json'})
            response=connection.getresponse(); body=response.read()
            if not 200 <= response.status < 300: raise RuntimeError('controller status '+str(response.status))
            return json.loads(body) if body else {}
        finally: connection.close()
    environment={k:v for k,v in os.environ.items() if 'proxy' not in k.lower()}
    with open(root/'log','wb') as log:
        process=subprocess.Popen([str(core),'-d',str(root),'-f',str(root/'config.yaml')],
                                 stdout=log,stderr=log,env=environment)
        try:
            for _ in range(100):
                if process.poll() is not None: raise RuntimeError('temporary core exited')
                try:
                    api('/version'); break
                except (OSError,RuntimeError): time.sleep(.1)
            else: raise RuntimeError('temporary controller did not start')
            relay=api('/proxies/Wired-Relay')
            destination=api('/proxies/Codex')
            print('relay choice count:',len(relay.get('all',[])))
            print('destination choice count:',len(destination.get('all',[])))
            targets=[name for name in destination.get('all',[]) if name != 'Auto-Destination'][:2]
            if not targets or working_relay not in relay.get('all',[]):
                raise RuntimeError('No suitable destination or relay; set PRIVATE_LINE_TEST_RELAY if needed')
            def check_exit():
                check=subprocess.run(['/usr/bin/curl','--noproxy','','--proxy',f'http://127.0.0.1:{port}',
                                      '--connect-timeout','4','--max-time','8','--silent','--show-error','--fail',
                                      'https://www.cloudflare.com/cdn-cgi/trace'],capture_output=True,text=True,env=environment)
                fields=dict(line.split('=',1) for line in check.stdout.splitlines() if '=' in line)
                actual=fields.get('ip')
                return check.returncode == 0 and bool(actual) and (not expected_exit or actual == expected_exit)
            working_targets=[]
            for target in targets:
                api('/proxies/Wired-Relay','PUT',{'name':'Unreachable-Relay'})
                api('/proxies/Codex','PUT',{'name':target})
                if api('/proxies/Wired-Relay').get('now') != 'Unreachable-Relay': raise RuntimeError('relay selection did not apply')
                if check_exit(): raise RuntimeError(target+' bypassed the deliberately unreachable relay')
                print(target,'cannot connect when relay is unreachable')
                api('/proxies/Wired-Relay','PUT',{'name':working_relay})
                if not check_exit():
                    print(target,'is currently unavailable through this relay; skipped')
                    continue
                working_targets.append(target)
                print(target,'succeeded through the real relay; exit verified' if expected_exit else 'succeeded through the real relay; exit obtained')
                api('/proxies/Wired-Relay','PUT',{'name':'Unreachable-Relay'})
                api('/configs?force=false','PUT',{'path':str(root/'config.yaml')})
                if api('/proxies/Wired-Relay').get('now') != 'Unreachable-Relay': raise RuntimeError('relay selection did not survive reload')
                if check_exit(): raise RuntimeError(target+' reused the previous tunnel after the relay changed')
                print(target,'new connection followed the changed relay')
            if not working_targets: raise RuntimeError('No destination passed the real relay check')
            helper=Path(__file__).resolve().parents[1]/'.build/route-rollback-test'
            if helper.exists():
                api('/proxies/Wired-Relay','PUT',{'name':working_relay})
                api('/proxies/Codex','PUT',{'name':working_targets[0]})
                api('/configs?force=false','PUT',{'path':str(root/'config.yaml')})
                subprocess.run([str(helper),str(root)],check=True,timeout=25)
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
