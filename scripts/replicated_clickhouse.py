"""Native boundary for the public owned migration fixture.

Resolve native ports only for exact HTTP endpoints reported by the live fixture,
then independently check UUIDs through Kansoku's native driver. No build-closure
inspection, ambient target adoption, or undocumented fixture imports.
"""
import json
import os
from pathlib import Path
import select
import socket
import socketserver
import subprocess
import threading
import urllib.parse


def native_ports(fixture, root):
    context = os.environ['CLICKHOUSE_MIGRATE_DOCKER_CONTEXT']
    docker = ['docker', '--context', context]
    containers = subprocess.check_output(docker + ['ps', '-q', '--filter', 'label=clickhouse-migrate.fixture=owned'], text=True, timeout=10).split()
    if not containers:
        raise RuntimeError('No owned replicated fixture containers')
    inspected = json.loads(subprocess.check_output(docker + ['inspect', *containers], text=True, timeout=10))
    selected = []
    for observation in fixture['replicas']:
        port = urllib.parse.urlsplit(observation['endpoint']).port
        matches = [c for c in inspected if any(int(p['HostPort']) == port and p['HostIp'] == '127.0.0.1' for p in c['NetworkSettings']['Ports'].get('8123/tcp', []) or [])]
        if len(matches) != 1:
            raise RuntimeError('HTTP endpoint must identify exactly one owned fixture container')
        container = matches[0]
        native = container['NetworkSettings']['Ports'].get('9000/tcp', []) or []
        if len(native) != 1 or native[0]['HostIp'] != '127.0.0.1':
            raise RuntimeError('Owned native port must bind dynamically to loopback')
        selected.append(dict(id=container['Id'], image=container['Image'], imageReference=container['Config']['Image'], nativePort=int(native[0]['HostPort']), network=list(container['NetworkSettings']['Networks'])))
    if selected[0]['id'] == selected[1]['id']:
        raise RuntimeError('Replica endpoints resolved to the same container')
    (root / 'containers.private.json').write_text(json.dumps(selected, indent=2))
    return [c['nativePort'] for c in selected]


class NativeProxy:
    """Connection round-robin with explicit reply hold/drop for lost-ack proof."""
    def __init__(self, ports):
        self.ports = ports
        self.next = 0
        self.forced_port = None
        self.held_port = None
        self.trace_marker = None
        self.trace_ports = []
        self.lock = threading.Lock()
        self.closed = False
        self.hold = threading.Event()
        self.drop = threading.Event()
        self.seen = threading.Event()
        self.reply_marker = None
        self.client_marker = None
        self.client_hold = threading.Event()
        self.client_seen = threading.Event()
        self.dropped = threading.Event()
        self.active = 0
        self.idle = threading.Event()
        self.idle.set()
        owner = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                with owner.lock:
                    owner.active += 1
                    owner.idle.clear()
                try:
                    self.forward()
                finally:
                    with owner.lock:
                        owner.active -= 1
                        if owner.active == 0:
                            owner.idle.set()

            def forward(self):
                with owner.lock:
                    port = owner.forced_port
                    if port is None:
                        port = owner.ports[owner.next % len(owner.ports)]
                        owner.next += 1
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=3) as upstream:
                        upstream.settimeout(None)
                        holding = False
                        tail = b''
                        traced_insert = False
                        while not owner.closed:
                            ready, _, _ = select.select([self.request, upstream], [], [], .1)
                            for source in ready:
                                if source is upstream and holding:
                                    owner.seen.set()
                                    while not owner.closed:
                                        if owner.drop.wait(.05):
                                            owner.dropped.set()
                                            return
                                data = source.recv(65536)
                                if not data:
                                    return
                                if source is self.request:
                                    window = tail + data
                                    if b'INSERT INTO events_raw' in window:
                                        traced_insert = False
                                    if owner.trace_marker and owner.trace_marker in window and not traced_insert:
                                        with owner.lock:
                                            owner.trace_ports.append(port)
                                        traced_insert = True
                                    if owner.client_marker and owner.client_marker in window:
                                        owner.client_seen.set()
                                        while owner.client_hold.is_set() and not owner.closed:
                                            owner.drop.wait(.05)
                                    if owner.reply_marker and owner.reply_marker in window:
                                        # The unique serialized row marker occurs only after
                                        # native sample negotiation, never in handshake/SQL.
                                        holding = True
                                        owner.held_port = port
                                        owner.reply_marker = None
                                    tail = window[-256:]
                                (upstream if source is self.request else self.request).sendall(data)
                except OSError:
                    return

        class Listener(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = True
        self.server = Listener(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.closed = True
        self.drop.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def configure_owned_capacity(root):
    """Give the full application schema room to recover after an unclean stop.

    The dependency's tiny-schema fixture caps the global pool at 128 and the
    background schedule pool at 8. Preserve its image, Keeper and profiles while
    explicitly sizing only these owned servers for the full native runtime proof.
    Apply before application migration and restart each server exactly once.
    """
    import xml.etree.ElementTree as ET
    docker = ['docker', '--context', os.environ['CLICKHOUSE_MIGRATE_DOCKER_CONTEXT']]
    containers = json.loads((root / 'containers.private.json').read_text())
    settings = {'max_thread_pool_size': '1024', 'background_schedule_pool_size': '64'}
    for index, container in enumerate(containers):
        original = root / f'replica-{index}-config.original.private.xml'
        configured = root / f'replica-{index}-config.private.xml'
        subprocess.run(docker + ['cp', container['id'] + ':/fixture/config.xml', str(original)], check=True, capture_output=True, timeout=10)
        tree = ET.parse(original)
        for name, value in settings.items():
            element = tree.getroot().find(name)
            if element is None:
                raise RuntimeError('Required owned fixture resource setting absent: ' + name)
            element.text = value
        tree.write(configured, encoding='utf-8')
        subprocess.run(docker + ['cp', str(configured), container['id'] + ':/fixture/config.xml'], check=True, capture_output=True, timeout=10)
    return settings
