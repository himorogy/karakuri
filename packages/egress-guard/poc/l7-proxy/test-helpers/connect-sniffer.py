#!/usr/bin/env python3
"""CONNECT スニファ — 「そのクライアントは本当にプロキシを使うのか」だけを見る道具。

プロキシのふりをして待ち受け、クライアントが最初に送ってきたバイト列を表示して
接続を切る。**中継はしない。** 外向きの通信は一切発生しない。

用途は 1 つだけ。`proxy-selection-research.md` §8 の未確認事項 9
（VS Code Server の拡張ギャラリークライアントが HTTPS_PROXY を読むか）を
実測すること。読むなら `CONNECT <host>:443` が表示され、読まないなら何も来ない。

    python3 connect-sniffer.py            # 既定 127.0.0.1:8899
    python3 connect-sniffer.py 0.0.0.0 8899

design.md §2.22 の実装ではない。検証用の使い捨てツール。
"""

import socket
import sys
import threading

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8899


def handle(conn: socket.socket, addr: tuple) -> None:
    with conn:
        conn.settimeout(5)
        try:
            data = conn.recv(4096)
        except socket.timeout:
            print(f"[{addr[0]}:{addr[1]}] 接続はあったが何も送ってこなかった", flush=True)
            return
        if not data:
            return
        first_line = data.split(b"\r\n", 1)[0].decode("latin-1")
        print(f"[{addr[0]}:{addr[1]}] {first_line}", flush=True)
        # 中継しないので、どのみち失敗させる。502 を返して切る。
        conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")


def main() -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(64)
    print(f"listening on {HOST}:{PORT} — 送られてきた最初の行だけを表示する", flush=True)
    print("何も表示されなければ、そのクライアントはプロキシ設定を読んでいない", flush=True)
    try:
        while True:
            conn, addr = srv.accept()
            threading.Thread(target=handle, args=(conn, addr), daemon=True).start()
    except KeyboardInterrupt:
        print("\n終了", flush=True)
    finally:
        srv.close()


if __name__ == "__main__":
    main()
