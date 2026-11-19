#!/usr/bin/python3
import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def receive(stream):
    size = bytearray()
    while len(size) <= 8:
        char = stream.read(1)
        if char == b':':
            return json.loads(stream.read(int(size)))
        if not char.isdigit():
            break
        size.extend(char)
    raise RuntimeError('Invalid Firefox response')


with tempfile.TemporaryDirectory() as profile:
    Path(profile, 'user.js').write_text('user_pref("marionette.port", 2829);\n')
    process = subprocess.Popen(['firefox', '--headless', '--no-remote', '--marionette',
                                '--profile', profile, 'about:blank'], stderr=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL)
    try:
        for attempt in range(100):
            try:
                connection = socket.create_connection(('127.0.0.1', 2829), timeout=1)
                break
            except OSError:
                if process.poll() is not None or attempt == 99:
                    raise
                time.sleep(.2)
        connection.settimeout(30)
        with connection, connection.makefile('rb') as stream:
            receive(stream)
            def command(name, params):
                payload = json.dumps([0, 1, name, params]).encode()
                connection.sendall(str(len(payload)).encode() + b':' + payload)
                _, _, error, result = receive(stream)
                if error:
                    raise RuntimeError(error['message'])
                return result
            command('WebDriver:NewSession', {'capabilities': {'alwaysMatch': {'pageLoadStrategy': 'normal'}}})
            command('WebDriver:Navigate', {'url': 'https://www.cloudflare.com/cdn-cgi/trace'})
            result = command('WebDriver:ExecuteScript', {
                'script': 'return [document.body.innerText, typeof RTCPeerConnection, typeof navigator.geolocation]',
                'args': [], 'sandbox': None, 'newSandbox': False})['value']
            trace = dict(line.split('=', 1) for line in result[0].splitlines() if '=' in line)
            expected = os.environ.get('EXPECTED_EGRESS_IP') or os.environ['VPS_IP']
            if (trace.get('ip'), trace.get('loc'), result[1:]) != (expected, 'US', ['undefined', 'undefined']):
                raise RuntimeError('Firefox 出口、WebRTC 或定位检查失败')
            print('Firefox: ' + expected + ' / US；WebRTC 和定位 API 均不可用')
    finally:
        process.terminate()
        try:
            process.wait(5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
