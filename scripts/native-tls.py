#!/usr/bin/env python3
"""Prove verified native TLS and fail-closed trust/hostname checks on owned sockets."""
from contextlib import contextmanager
from pathlib import Path
import os
import socket
import ssl
import subprocess
import threading

from isolated_clickhouse import isolated_clickhouse, owned_clickhouse_root
from test_support import binary, execute


@contextmanager
def proxy(upstream_port, certificate, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    family, kind, protocol, _, address = socket.getaddrinfo(
        'localhost', None, type=socket.SOCK_STREAM, flags=socket.AI_ADDRCONFIG)[0]
    assert address[0] in ('127.0.0.1', '::1'), 'localhost must resolve to loopback'
    listener = socket.socket(family, kind, protocol)
    listener.bind(address)
    listener.listen()
    listener.settimeout(.2)
    stopped = threading.Event()
    connections = []
    workers = []
    evidence = {'application_bytes': 0}

    def serve(raw):
        try:
            with context.wrap_socket(raw, server_side=True) as secure:
                connections.append(secure)
                with socket.create_connection(('127.0.0.1', upstream_port), timeout=5) as upstream:
                    upstream.settimeout(None)
                    connections.append(upstream)

                    def forward():
                        try:
                            while data := secure.recv(65536):
                                evidence['application_bytes'] += len(data)
                                upstream.sendall(data)
                        except OSError:
                            pass
                        finally:
                            try:
                                upstream.shutdown(socket.SHUT_RDWR)
                            except OSError:
                                pass

                    sender = threading.Thread(target=forward, daemon=True)
                    sender.start()
                    try:
                        while data := upstream.recv(65536):
                            secure.sendall(data)
                    except OSError:
                        pass
                    finally:
                        try:
                            secure.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
                        sender.join(timeout=5)
        except OSError:
            raw.close()

    def accept():
        while not stopped.is_set():
            try:
                raw, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            connections.append(raw)
            worker = threading.Thread(target=serve, args=(raw,), daemon=True)
            workers.append(worker)
            worker.start()

    thread = threading.Thread(target=accept, daemon=True)
    thread.start()
    try:
        yield listener.getsockname()[1], evidence
    finally:
        stopped.set()
        listener.close()
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        thread.join(timeout=5)
        for worker in workers:
            worker.join(timeout=5)
        if thread.is_alive() or any(worker.is_alive() for worker in workers):
            raise RuntimeError('Owned TLS proxy did not stop')


def certificate(root, name, san):
    cert, key = root / (name + '.pem'), root / (name + '.key')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-days', '1', '-subj', '/CN=' + name, '-addext', 'subjectAltName=' + san,
                    '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    return cert, key


def verify(env, root):
    executable = binary('kansoku-core:test:kansoku-core-test')
    settings = dict(env, KANSOKU_TLS_PROBE_CHILD='1', KANSOKU_CLICKHOUSE_DATABASE='default')
    settings.pop('SSL_CERT_DIR', None)

    def probe(label, port, trust, secure=True):
        result = execute([executable], env=dict(settings, CLICKHOUSE_TCP_PORT=str(port),
                         KANSOKU_CLICKHOUSE_HOST='localhost' if secure else '127.0.0.1',
                         KANSOKU_CLICKHOUSE_SECURE=str(secure).lower(), SSL_CERT_FILE=str(trust)),
                         timeout=30)
        (root / (label + '.log')).write_text(result.stdout + result.stderr)
        return result

    trusted, trusted_key = certificate(root, 'trusted', 'DNS:localhost')
    stranger, stranger_key = certificate(root, 'stranger', 'DNS:localhost')
    wrong, wrong_key = certificate(root, 'wrong-host', 'DNS:wrong.invalid')
    upstream = int(env['CLICKHOUSE_TCP_PORT'])
    result = probe('plaintext-default', upstream, trusted, secure=False)
    result.check_returncode()
    with proxy(upstream, trusted, trusted_key) as (port, evidence):
        result = probe('verified-tls', port, trusted)
        result.check_returncode()
        assert evidence['application_bytes'] > 0, 'positive case never reached native protocol'
    for label, cert, key, trust in [('untrusted', stranger, stranger_key, trusted),
                                    ('hostname', wrong, wrong_key, wrong)]:
        with proxy(upstream, cert, key) as (port, evidence):
            result = probe(label, port, trust)
            output = (result.stdout + result.stderr).lower()
            assert result.returncode != 0 and 'certificate' in output, label + ' did not fail certificate validation'
            assert evidence['application_bytes'] == 0, label + ' sent native credentials before verification'
    print('Native TLS: plaintext and verified TLS pass; untrusted and wrong-host certificates refused before native bytes', flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    with owned_clickhouse_root(None) as directory:
        with isolated_clickhouse() as env:
            verify(env, Path(directory))
