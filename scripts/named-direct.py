#!/usr/bin/python3
import ipaddress
import os
import socket
import socketserver
import subprocess

import dns.flags
import dns.message
import dns.query
import dns.rcode
import dns.rdatatype
import dns.resolver
import dns.rrset

DOMAINS = tuple(item.strip().lower() + '.' for item in os.getenv('DIRECT_DOMAINS', '').split(',') if item.strip())
UPSTREAM = str(ipaddress.IPv4Address(os.getenv('INTERNAL_DNS_SERVER') or '1.1.1.1'))
pool = ipaddress.ip_network('198.18.0.0/15').hosts()
MAC_DOMAINS = tuple(item.strip().lower() + '.' for item in os.getenv('MAC_DNS_DOMAINS', '').split(',') if item.strip())
aliases = {}


def alias(address, from_mac=False):
    if address not in aliases:
        if not ipaddress.ip_address(address).is_global:
            if ipaddress.ip_address(address) in ipaddress.ip_network('10.0.0.0/8'):
                return address
            private_lan = any(ipaddress.ip_address(address) in ipaddress.ip_network(network)
                              for network in ('192.168.0.0/16', '172.16.0.0/12', '100.64.0.0/10'))
            if not (from_mac and private_lan):
                raise ValueError('non-public bypass destination')
        synthetic = str(next(pool))
        subprocess.run(['nft', 'add', 'element', 'inet', 'cage', 'destinations',
                        '{', synthetic, ':', address, '}'], check=True)
        aliases[address] = synthetic
    return aliases[address]


def answer(wire):
    request = dns.message.from_wire(wire)
    result = dns.message.make_response(request)
    result.flags |= dns.flags.RA
    try:
        question, = request.question
        name = str(question.name).lower()
        if not any(name == suffix or name.endswith('.' + suffix) for suffix in DOMAINS + MAC_DOMAINS):
            result.set_rcode(dns.rcode.REFUSED)
        elif any(name == suffix or name.endswith('.' + suffix) for suffix in MAC_DOMAINS):
            if question.rdtype == dns.rdatatype.A:
                with open('/run/cage-mac-ip') as endpoint:
                    bridge = str(ipaddress.IPv4Address(endpoint.read().strip()))
                with socket.create_connection((bridge, 38543), timeout=4) as conn:
                    conn.sendall(name[:-1].encode('ascii') + b'\n')
                    with conn.makefile('rb') as stream:
                        response = stream.readline(4096).decode('ascii').strip()
                if response == 'NOTFOUND':
                    result.set_rcode(dns.rcode.NXDOMAIN)
                else:
                    addresses = [alias(str(ipaddress.IPv4Address(item)), True) for item in response.split()]
                    if not addresses:
                        raise ValueError('empty host response')
                    result.answer.append(dns.rrset.from_text_list(question.name, 15, 'IN', 'A', addresses))
        elif question.rdtype == dns.rdatatype.A:
            resolver = dns.resolver.Resolver(configure=False)
            resolver.nameservers = [UPSTREAM]
            records = resolver.resolve(question.name, 'A', lifetime=4, search=False)
            result.answer.append(dns.rrset.from_text_list(question.name, min(60, records.rrset.ttl),
                                                          'IN', 'A', [alias(item.address) for item in records]))
        elif question.rdtype not in (dns.rdatatype.AAAA, dns.rdatatype.HTTPS, dns.rdatatype.SVCB, dns.rdatatype.ANY):
            result = dns.query.tcp(request, UPSTREAM, timeout=4)
    except dns.resolver.NXDOMAIN:
        result.set_rcode(dns.rcode.NXDOMAIN)
    except dns.resolver.NoAnswer:
        pass
    except Exception:
        result.set_rcode(dns.rcode.SERVFAIL)
    return result.to_wire()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        sock.sendto(answer(packet), self.client_address)


if __name__ == '__main__':
    with socketserver.UDPServer(('127.0.0.1', 5354), Handler) as server:
        server.serve_forever()
