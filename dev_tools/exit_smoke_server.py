"""Isolated native-client exit smoke fixture; never imports OAS or ADB.

Listens only on 127.0.0.1:22392. A shutdown request records evidence and exits
this fixture process, not any other backend. Run with a separate client profile.
"""

import asyncio
import json
from pathlib import Path

import uvicorn

from ui_preview_server import create_app


HOST = '127.0.0.1'
PORT = 22392
EVIDENCE = Path(__file__).resolve().parent.parent / 'log' / 'exit-smoke-events.json'
app = create_app()
events = {'kind': 'oasx-exit-smoke', 'port': PORT, 'shutdown_requests': 0}
server = None


def save_evidence():
    EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
    EVIDENCE.write_text(json.dumps(events), encoding='utf-8')


@app.get('/exit_smoke_identity')
def identity():
    return events


@app.get('/home/kill_server')
async def shutdown_fixture():
    events['shutdown_requests'] += 1
    save_evidence()
    # Allow the success acknowledgement to flush before this fixture exits.
    asyncio.get_running_loop().call_later(0.25, request_shutdown)
    return 'success'


def request_shutdown():
    if server is not None:
        server.should_exit = True


if __name__ == '__main__':
    save_evidence()
    server = uvicorn.Server(uvicorn.Config(
        app, host=HOST, port=PORT, log_level='warning',
        timeout_graceful_shutdown=2,
    ))
    server.run()
