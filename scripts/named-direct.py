#!/usr/bin/python3
import ipaddress
import os
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
aliases = {}


def alias(address):
    if address not in aliases:
        if not ipaddress.ip_address(address).is_global:
            if ipaddress.ip_address(address) in ipaddress.ip_network('10.0.0.0/8'):
                return address
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
        if not any(name == suffix or name.endswith('.' + suffix) for suffix in DOMAINS):
            result.set_rcode(dns.rcode.REFUSED)
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
