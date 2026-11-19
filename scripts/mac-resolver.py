#!/usr/bin/env python3
import re
import socket
import socketserver
import sys

LABEL = re.compile(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?')
SUFFIXES = tuple(value.strip().lower() for value in sys.argv[1].split(','))
if not all(value and all(LABEL.fullmatch(label) for label in value.split('.')) for value in SUFFIXES):
    raise SystemExit('invalid suffix list')


class Resolver(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(4)
        name = self.rfile.readline(256).decode('ascii').strip().lower()
        if len(name) > 253 or not all(LABEL.fullmatch(label) for label in name.split('.')):
            return
        if not any(name == suffix or name.endswith('.' + suffix) for suffix in SUFFIXES):
            self.wfile.write(b'REFUSED\n')
            return
        try:
            addresses = socket.getaddrinfo(name + '.', None, socket.AF_INET, socket.SOCK_STREAM)
            response = ' '.join(dict.fromkeys(item[4][0] for item in addresses))
        except socket.gaierror as error:
            response = 'NOTFOUND' if error.errno in (socket.EAI_NONAME, socket.EAI_NODATA) else 'ERROR'
        self.wfile.write((response + '\n').encode('ascii'))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(('127.0.0.1', 38543), Resolver) as server:
    server.serve_forever()
