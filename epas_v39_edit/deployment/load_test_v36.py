"""EPAS v3.6 lightweight HTTP load harness.
Set EPAS_LOAD_TEST_URL to the deployed Streamlit URL and run this script from a controlled test host.
"""
import os, time, statistics
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

URL=os.getenv("EPAS_LOAD_TEST_URL")
USERS=int(os.getenv("EPAS_LOAD_TEST_USERS","10"))
ITERATIONS=int(os.getenv("EPAS_LOAD_TEST_ITERATIONS","5"))
TIMEOUT=float(os.getenv("EPAS_LOAD_TEST_TIMEOUT","15"))

def one():
    if not URL: return (False,0.0,'EPAS_LOAD_TEST_URL not set')
    t=time.perf_counter()
    try:
        req=Request(URL,headers={'User-Agent':'EPAS-v3.6-load-test'})
        with urlopen(req,timeout=TIMEOUT) as r:
            r.read(256)
            return (200 <= r.status < 500, time.perf_counter()-t, str(r.status))
    except (HTTPError,URLError,TimeoutError) as e:
        return (False,time.perf_counter()-t,type(e).__name__)

def main():
    if not URL:
        print('Set EPAS_LOAD_TEST_URL before running.'); return
    samples=[]
    with ThreadPoolExecutor(max_workers=USERS) as pool:
        futures=[pool.submit(one) for _ in range(USERS*ITERATIONS)]
        for f in as_completed(futures): samples.append(f.result())
    ok=[x[1] for x in samples if x[0]]
    fail=len(samples)-len(ok)
    print(f'EPAS v3.6 load test: requests={len(samples)} ok={len(ok)} failed={fail}')
    if ok:
        print(f'p50={statistics.median(ok):.3f}s max={max(ok):.3f}s mean={statistics.mean(ok):.3f}s')

if __name__=='__main__': main()
