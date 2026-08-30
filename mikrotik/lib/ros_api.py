#!/usr/bin/env python3
"""Client de l'API binaire RouterOS (port 8728 en clair, 8729 en TLS).

Ne connait que le protocole : encodage des longueurs, phrases, login.
Aucune dependance hors bibliotheque standard -- le depot doit rester
utilisable depuis n'importe quelle machine du lab.
"""
import os
import socket
import ssl


class RosApiError(Exception):
    """Le routeur a renvoye !trap ou !fatal."""


def _enc_len(n):
    if n < 0x80:
        return bytes([n])
    if n < 0x4000:
        return (n | 0x8000).to_bytes(2, "big")
    if n < 0x200000:
        return (n | 0xC00000).to_bytes(3, "big")
    if n < 0x10000000:
        return (n | 0xE0000000).to_bytes(4, "big")
    return b"\xf0" + n.to_bytes(4, "big")


class Ros:
    def __init__(self, host, port=8729, use_ssl=True, timeout=15):
        sock = socket.create_connection((host, port), timeout=timeout)
        if use_ssl:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            # Sans certificat associe au service api-ssl, RouterOS negocie en
            # anonyme (ADH) : OpenSSL le refuse au niveau de securite par
            # defaut, il faut l'abaisser explicitement.
            try:
                ctx.set_ciphers("ADH:@SECLEVEL=0")
            except ssl.SSLError:
                ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
            sock = ctx.wrap_socket(sock)
        self.sock = sock
        self.buf = b""

    # --- couche octets ----------------------------------------------------
    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RosApiError("connexion fermee par le routeur")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _read_len(self):
        b0 = self._read(1)[0]
        if b0 & 0x80 == 0:
            return b0
        if b0 & 0xC0 == 0x80:
            return ((b0 & 0x3F) << 8) + self._read(1)[0]
        if b0 & 0xE0 == 0xC0:
            return ((b0 & 0x1F) << 16) + int.from_bytes(self._read(2), "big")
        if b0 & 0xF0 == 0xE0:
            return ((b0 & 0x0F) << 24) + int.from_bytes(self._read(3), "big")
        return int.from_bytes(self._read(4), "big")

    # --- couche phrases ---------------------------------------------------
    def send(self, words):
        out = b"".join(_enc_len(len(w.encode())) + w.encode() for w in words)
        self.sock.sendall(out + b"\x00")

    def read_sentence(self):
        words = []
        while True:
            n = self._read_len()
            if n == 0:
                return words
            words.append(self._read(n).decode(errors="replace"))

    def talk(self, words):
        """Envoie une commande, renvoie la liste des lignes de reponse."""
        self.send(words)
        replies = []
        while True:
            sentence = self.read_sentence()
            if not sentence:
                continue
            tag, attrs = sentence[0], {}
            for w in sentence[1:]:
                if w.startswith("="):
                    k, _, v = w[1:].partition("=")
                    attrs[k] = v
            if tag == "!done":
                if attrs:
                    replies.append(attrs)
                return replies
            if tag in ("!trap", "!fatal"):
                raise RosApiError(attrs.get("message", " ".join(sentence)))
            replies.append(attrs)

    def login(self, user, password):
        self.talk(["/login", f"=name={user}", f"=password={password}"])

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def connect_from_env():
    """Ouvre une session a partir de MIKROTIK_HOST / _USER / _PASSWORD."""
    password = os.environ.get("MIKROTIK_PASSWORD")
    if not password:
        raise SystemExit(
            "MIKROTIK_PASSWORD n'est pas defini.\n"
            "Renseigne mikrotik/secrets.env (voir secrets.rsc.example) "
            "ou exporte la variable."
        )
    ros = Ros(os.environ.get("MIKROTIK_HOST", "192.168.100.1"))
    ros.login(os.environ.get("MIKROTIK_USER", "admin"), password)
    return ros
