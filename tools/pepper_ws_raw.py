"""Minimal WebSocket client using only Python stdlib.

Used as a fallback when the `websockets` library has compatibility issues
with NWProtocolWebSocket (e.g., Python 3.14 on macOS CI runners).

Only supports unmasked text frames (sufficient for pepper JSON protocol).
"""

import base64
import hashlib
import os
import socket
import struct


class RawWebSocket:
    """Minimal RFC 6455 WebSocket client over a raw TCP socket."""

    MAGIC = b"258EAFA5-E914-47DA-95CF-665DDA151497"

    def __init__(self, sock):
        self._sock = sock
        self._buf = b""

    @classmethod
    def connect(cls, host, port, timeout=5):
        """Perform TCP connect + WebSocket upgrade handshake."""
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.settimeout(timeout)

        # Generate random key
        key = base64.b64encode(os.urandom(16)).decode()
        expected_accept = base64.b64encode(
            hashlib.sha1((key + cls.MAGIC.decode()).encode()).digest()
        ).decode()

        # Send HTTP upgrade
        req = (
            f"GET / HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"\r\n"
        )
        sock.sendall(req.encode())

        # Read upgrade response
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("Connection closed during handshake")
            resp += chunk

        if b"101" not in resp.split(b"\r\n")[0]:
            first_line = resp.split(b"\r\n")[0]
            raise ConnectionError(f"WebSocket upgrade failed: {first_line}")

        # Save any data read past the HTTP headers (may contain WS frames)
        ws = cls(sock)
        header_end = resp.index(b"\r\n\r\n") + 4
        ws._buf = resp[header_end:]
        return ws

    def send(self, text):
        """Send a masked text frame (RFC 6455 §5.1: client MUST mask)."""
        payload = text.encode("utf-8")
        mask_key = os.urandom(4)

        # Build frame header
        header = bytearray()
        header.append(0x81)  # FIN + text opcode

        length = len(payload)
        if length < 126:
            header.append(0x80 | length)  # MASK bit + length
        elif length < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack(">H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack(">Q", length))

        header.extend(mask_key)

        # Mask payload
        masked = bytearray(len(payload))
        for i, b in enumerate(payload):
            masked[i] = b ^ mask_key[i % 4]

        self._sock.sendall(bytes(header) + bytes(masked))

    def recv(self, timeout=10):
        """Receive a text frame, return the payload as str."""
        self._sock.settimeout(timeout)

        # Read at least 2 bytes for the header
        while len(self._buf) < 2:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise ConnectionError("Connection closed")
            self._buf += chunk

        b0, b1 = self._buf[0], self._buf[1]
        masked = bool(b1 & 0x80)
        length = b1 & 0x7F
        offset = 2

        if length == 126:
            while len(self._buf) < offset + 2:
                self._buf += self._sock.recv(4096)
            length = struct.unpack(">H", self._buf[offset:offset+2])[0]
            offset += 2
        elif length == 127:
            while len(self._buf) < offset + 8:
                self._buf += self._sock.recv(4096)
            length = struct.unpack(">Q", self._buf[offset:offset+8])[0]
            offset += 8

        if masked:
            offset += 4  # skip mask key (servers shouldn't mask, but handle it)

        # Read full payload
        while len(self._buf) < offset + length:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise ConnectionError("Connection closed mid-frame")
            self._buf += chunk

        payload = self._buf[offset:offset+length]
        if masked:
            mask_key = self._buf[offset-4:offset]
            payload = bytearray(payload)
            for i in range(len(payload)):
                payload[i] ^= mask_key[i % 4]
            payload = bytes(payload)

        self._buf = self._buf[offset+length:]

        opcode = b0 & 0x0F
        if opcode == 0x8:  # close frame
            raise ConnectionError("Server sent close frame")
        if opcode == 0x9:  # ping
            self._send_pong(payload)
            return self.recv(timeout)  # recurse to get actual data

        return payload.decode("utf-8")

    def _send_pong(self, payload):
        """Send a pong frame."""
        header = bytearray([0x8A, 0x80 | len(payload)])
        mask_key = os.urandom(4)
        header.extend(mask_key)
        masked = bytearray(len(payload))
        for i, b in enumerate(payload):
            masked[i] = b ^ mask_key[i % 4]
        self._sock.sendall(bytes(header) + bytes(masked))

    def close(self):
        """Send close frame and shut down."""
        try:
            # Send close frame
            mask_key = os.urandom(4)
            self._sock.sendall(bytes([0x88, 0x82]) + mask_key + bytes([
                0x03 ^ mask_key[0], 0xE8 ^ mask_key[1]  # status 1000
            ]))
        except OSError:
            pass
        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self._sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
