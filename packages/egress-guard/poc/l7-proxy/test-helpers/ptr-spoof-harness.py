#!/usr/bin/env python3
"""V6 (design.md #2.22 の必須要件A) を再現するための検証専用ハーネス。

これは実装ではなく、検証用の使い捨てツール。以下の2つを1プロセスでやる。

1. UDP/53: どんなPTR問い合わせにも「PTR_FAKE_NAME」(既定 deb.debian.org.)
   で答える。dstdomain -n の無いsquidなら、CONNECT <このコンテナのIP>:443
   宛の接続がこの偽名でallowedにマッチしてしまう、という攻撃条件を作る。
2. TCP/443: 接続を受けたらその事実をstdoutへ記録するだけのリスナ。
   ここへ接続が来た場合、それは「-n が無ければ攻撃が成立する」ことの
   直接証拠になる。逆に一度も接続が来なければ、-n が効いて
   CONNECT がsquid側でdenyされたことの状況証拠になる
   (verify.shはsquidのアクセスログ側でも deny を確認する)。

DNSのパース/組み立ては標準ライブラリのみで手書きしている。この用途に
dnspython等の外部ライブラリを足す理由が無い(答える内容が固定なため)。
"""
from __future__ import annotations

import os
import socket
import struct
import sys
import threading
import time

PTR_FAKE_NAME = os.environ.get("PTR_FAKE_NAME", "deb.debian.org")
DNS_PORT = 53
TCP_PORT = 443


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def encode_name(name: str) -> bytes:
    out = b""
    for label in name.rstrip(".").split("."):
        encoded = label.encode("ascii")
        out += struct.pack("B", len(encoded)) + encoded
    return out + b"\x00"


def parse_question_name(data: bytes, offset: int) -> tuple[bytes, int]:
    """Return the raw (still encoded) QNAME bytes and the offset right after it.

    No compression is expected in an incoming question, so this does not need
    to follow pointers - only to find where the name ends.
    """
    start = offset
    while True:
        length = data[offset]
        if length == 0:
            offset += 1
            break
        offset += 1 + length
    return data[start:offset], offset


def build_ptr_response(query: bytes) -> bytes | None:
    if len(query) < 12:
        return None
    txn_id = query[0:2]
    flags_in = struct.unpack("!H", query[2:4])[0]
    qdcount = struct.unpack("!H", query[4:6])[0]
    if qdcount != 1:
        return None

    qname_raw, after_name = parse_question_name(query, 12)
    if len(query) < after_name + 4:
        return None
    qtype, qclass = struct.unpack("!HH", query[after_name : after_name + 4])

    # qtype 12 = PTR, qclass 1 = IN. Anything else is out of scope for this
    # single-purpose harness - the goal is only to answer the PTR lookup
    # squid issues while evaluating `acl allowed dstdomain <no -n>`.
    if qtype != 12 or qclass != 1:
        return None

    header = struct.pack(
        "!HHHHHH",
        struct.unpack("!H", txn_id)[0],
        0x8180 | (flags_in & 0x0100),  # QR=1, RA mirrors RD, RCODE=0
        1,  # QDCOUNT
        1,  # ANCOUNT
        0,  # NSCOUNT
        0,  # ARCOUNT
    )
    question = qname_raw + struct.pack("!HH", qtype, qclass)

    rdata = encode_name(PTR_FAKE_NAME)
    answer = (
        b"\xc0\x0c"  # NAME: pointer back to the question at offset 12
        + struct.pack("!HH", 12, 1)  # TYPE=PTR, CLASS=IN
        + struct.pack("!I", 60)  # TTL
        + struct.pack("!H", len(rdata))
        + rdata
    )
    return header + question + answer


def run_dns_server() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", DNS_PORT))
    log(f"fake PTR responder listening on udp/{DNS_PORT}, answering everything as {PTR_FAKE_NAME}")
    while True:
        try:
            data, addr = sock.recvfrom(512)
            response = build_ptr_response(data)
            if response is not None:
                sock.sendto(response, addr)
                log(f"answered PTR query from {addr} with {PTR_FAKE_NAME}")
            else:
                log(f"ignored non-PTR query from {addr}")
        except Exception as exc:  # noqa: BLE001 - this is a throwaway test tool
            log(f"dns handler error: {exc}")


def run_tcp_victim() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", TCP_PORT))
    sock.listen(20)
    log(f"victim listener on tcp/{TCP_PORT} - any connection here means the spoof got through")
    while True:
        conn, addr = sock.accept()
        log(f"!!! SPOOF SUCCEEDED: received a connection from {addr} on the victim port !!!")
        conn.close()


def main() -> int:
    threading.Thread(target=run_dns_server, daemon=True).start()
    run_tcp_victim()
    return 0


if __name__ == "__main__":
    sys.exit(main())
