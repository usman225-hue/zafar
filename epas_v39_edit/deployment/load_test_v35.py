"""Lightweight production load-test harness for the Streamlit/Supabase stack.
This is intentionally dependency-light. It can run smoke concurrency against a
health endpoint or an authorized API endpoint supplied by the deployment team.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import time
import urllib.request


def hit(url: str, timeout: float = 10.0) -> tuple[bool, float, int]:
    start=time.perf_counter()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            r.read(512)
            return True, time.perf_counter()-start, r.status
    except Exception:
        return False, time.perf_counter()-start, 0


def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument('--url', required=True, help='Authorized health/landing URL')
    ap.add_argument('--users', type=int, default=10)
    ap.add_argument('--rounds', type=int, default=3)
    args=ap.parse_args()
    samples=[]
    failures=0
    for _ in range(max(1,args.rounds)):
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1,args.users)) as pool:
            for ok, elapsed, status in pool.map(lambda _: hit(args.url), range(max(1,args.users))):
                samples.append(elapsed)
                failures += 0 if ok else 1
    samples.sort()
    p95=samples[min(len(samples)-1, max(0,int(len(samples)*0.95)-1))] if samples else 0
    print({
        'requests': len(samples), 'failures': failures,
        'avg_seconds': round(sum(samples)/len(samples),3) if samples else None,
        'p95_seconds': round(p95,3) if samples else None,
    })
    return 1 if failures else 0

if __name__ == '__main__':
    raise SystemExit(main())
