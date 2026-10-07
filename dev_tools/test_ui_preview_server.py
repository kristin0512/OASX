"""Exercise the preview's real ASGI routes without a server, sockets, or OAS.

Run with a Python containing FastAPI: python -m unittest discover -s dev_tools.
The tiny transport below avoids adding httpx to the live backend environment.
"""

import asyncio
from contextlib import asynccontextmanager
from datetime import datetime
import json
import unittest
from urllib.parse import urlencode

from ui_preview_server import DATA_PATH, DEMO_NAMES, HOST, PORT, create_app


async def request(app, path, method='GET', **params):
    received = []
    scope = {
        'type': 'http', 'asgi': {'version': '3.0'}, 'http_version': '1.1',
        'method': method, 'scheme': 'http', 'path': path,
        'raw_path': path.encode('utf-8'), 'root_path': '',
        'query_string': urlencode(params).encode('utf-8'),
        'headers': [(b'host', b'fixture')],
        'client': ('fixture', 1), 'server': ('fixture', PORT),
    }

    async def receive():
        return {'type': 'http.request', 'body': b'', 'more_body': False}

    async def send(message):
        received.append(message)

    await app(scope, receive, send)
    status = next(m['status'] for m in received if m['type'] == 'http.response.start')
    body = b''.join(m.get('body', b'') for m in received if m['type'] == 'http.response.body')
    return status, json.loads(body) if body else None


@asynccontextmanager
async def websocket(app, name):
    incoming, outgoing = asyncio.Queue(), asyncio.Queue()
    scope = {
        'type': 'websocket', 'asgi': {'version': '3.0'}, 'http_version': '1.1',
        'scheme': 'ws', 'path': f'/ws/{name}', 'root_path': '',
        'query_string': b'', 'headers': [], 'subprotocols': [],
        'client': ('fixture', 1), 'server': ('fixture', PORT),
    }
    await incoming.put({'type': 'websocket.connect'})
    task = asyncio.create_task(app(scope, incoming.get, outgoing.put))

    async def next_message():
        return await asyncio.wait_for(outgoing.get(), timeout=3)

    async def command(text):
        await incoming.put({'type': 'websocket.receive', 'text': text})

    try:
        yield next_message, command
    finally:
        await incoming.put({'type': 'websocket.disconnect', 'code': 1000})
        await asyncio.wait_for(task, timeout=3)


class PreviewFixtureTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.app = create_app()
        self.name = DEMO_NAMES[1]
        self.original_data = DATA_PATH.read_bytes()

    def tearDown(self):
        self.assertEqual(DATA_PATH.read_bytes(), self.original_data,
                         'Preview requests must never persist configuration')

    async def test_identity_and_runhey_statistics_capability(self):
        self.assertEqual((HOST, PORT), ('127.0.0.1', 22391))
        code, identity = await request(self.app, '/preview_identity')
        self.assertEqual(code, 200)
        self.assertEqual(identity['kind'], 'oasx-azurtian-preview')
        self.assertTrue(identity['demo'])
        self.assertFalse(identity['supports_statistics'])
        self.assertEqual(await request(self.app, '/test'), (200, 'success'))
        code, spec = await request(self.app, '/openapi.json')
        self.assertEqual(code, 200)
        self.assertIn('/{name}/{task}/args', spec['paths'])
        self.assertFalse(any(path.startswith('/stats/') for path in spec['paths']))
        self.assertFalse(any(path.startswith('/logs/') for path in spec['paths']))
        code, _ = await request(self.app, f'/stats/{self.name}/dates')
        self.assertEqual(code, 404)

    async def test_every_menu_task_has_native_argument_schema(self):
        code, names = await request(self.app, '/config_list')
        self.assertEqual(code, 200)
        self.assertEqual(names, list(DEMO_NAMES))
        self.assertTrue(all('演示' in name for name in names))
        _, menu = await request(self.app, '/script_menu')
        self.assertIn('Chess', menu['Weekly Task'])
        task_names = [task for tasks in menu.values() for task in tasks]
        self.assertGreater(len(task_names), 50)
        for task in task_names:
            with self.subTest(task=task):
                code, schema = await request(self.app, f'/{self.name}/{task}/args')
                self.assertEqual(code, 200)
                for entries in schema.values():
                    self.assertIsInstance(entries, list)
                    for entry in entries:
                        self.assertTrue({'name', 'type', 'default', 'value'} <= entry.keys())
                        if entry['type'] == 'enum':
                            self.assertIn(entry['value'], entry['enumEnum'])
        _, chess = await request(self.app, f'/{self.name}/Chess/args')
        self.assertEqual(len(chess['chess_config']), 7)
        self.assertEqual(len(chess['chess_config'][0]['enumEnum']), 7)
        _, translations = await request(self.app, '/home/additional_translate')
        self.assertEqual(translations['zh-CN']['Chess'], '百鬼棋局')

    async def test_typed_argument_roundtrip_and_account_isolation(self):
        path = f'/{self.name}/Chess/chess_config/run_count/value'
        self.assertEqual(await request(self.app, path, 'PUT', types='integer', value='3'),
                         (200, True))
        _, schema = await request(self.app, f'/{self.name}/Chess/args')
        self.assertEqual(schema['chess_config'][2]['value'], 3)
        _, other = await request(self.app, f'/{DEMO_NAMES[0]}/Chess/args')
        self.assertEqual(other['chess_config'][2]['value'], 1)
        for types, value in [('boolean', 'true'), ('integer', 'not a number')]:
            code, _ = await request(self.app, path, 'PUT', types=types, value=value)
            self.assertEqual(code, 422)
        bool_path = f'/{self.name}/Chess/chess_config/rank_protection/value'
        self.assertEqual(await request(self.app, bool_path, 'PUT', types='boolean', value='true'),
                         (200, True))
        _, schema = await request(self.app, f'/{self.name}/Chess/args')
        self.assertIs(schema['chess_config'][1]['value'], True)
        fresh = create_app()
        _, reset = await request(fresh, f'/{self.name}/Chess/args')
        self.assertEqual(reset['chess_config'][2]['value'], 1)

    async def test_configuration_crud_and_copy_use_native_query_names(self):
        _, new_name = await request(self.app, '/config_new_name')
        code, names = await request(self.app, '/config_copy', 'POST',
                                    file=new_name, template=self.name)
        self.assertEqual(code, 200)
        self.assertIn(new_name, names)
        await request(self.app, f'/{self.name}/Chess/chess_config/run_count/value',
                      'PUT', types='integer', value='7')
        _, schema = await request(self.app, f'/{new_name}/Chess/args')
        self.assertEqual(schema['chess_config'][2]['value'], 1)
        self.assertEqual(await request(self.app, '/config/task/group/copy', 'PUT',
                                       task_name='Chess', group_name='chess_config',
                                       source_config_name=self.name, dest_config_name=new_name),
                         (200, True))
        _, schema = await request(self.app, f'/{new_name}/Chess/args')
        self.assertEqual(schema['chess_config'][2]['value'], 7)
        self.assertEqual(await request(self.app, '/config/task/copy', 'PUT',
                                       task_name='Orochi', source_config_name=self.name,
                                       dest_config_name=new_name), (200, True))
        renamed = '演示-改名配置'
        self.assertEqual(await request(self.app, '/config', 'PUT', old_name=new_name,
                                       new_name=renamed), (200, True))
        self.assertEqual(await request(self.app, '/config', 'DELETE', name=renamed), (200, True))
        code, _ = await request(self.app, '/config_copy', 'POST', file='real-profile',
                                template='template')
        self.assertEqual(code, 422)

    async def test_sync_next_run_updates_argument_and_legacy_schedule(self):
        target = '2030-01-02 03:04:05'
        self.assertEqual(await request(self.app, f'/{self.name}/Chess/sync_next_run',
                                       'PUT', target_dt=target), (200, True))
        _, schema = await request(self.app, f'/{self.name}/Chess/args')
        self.assertEqual(schema['scheduler'][1]['value'], target)
        async with websocket(self.app, self.name) as (receive, _):
            self.assertEqual((await receive())['type'], 'websocket.accept')
            self.assertEqual(json.loads((await receive())['text']), {'state': 1})
            schedule = json.loads((await receive())['text'])['schedule']
            self.assertEqual(schedule['running'], {'name': 'Chess', 'next_run': target})

    async def test_legacy_websocket_text_logs_and_scheduler_controls(self):
        async with websocket(self.app, self.name) as (receive, command):
            self.assertEqual((await receive())['type'], 'websocket.accept')
            self.assertEqual(json.loads((await receive())['text']), {'state': 1})
            schedule = json.loads((await receive())['text'])['schedule']
            self.assertEqual(schedule['running']['name'], 'Chess')
            for item in [schedule['running'], *schedule['pending'], *schedule['waiting']]:
                datetime.fromisoformat(item['next_run'])
            demo_log = (await receive())['text']
            self.assertTrue(demo_log.startswith('INFO '))
            self.assertIn('演示', demo_log)
            self.assertIn('不是游戏实机状态', demo_log)
            for command_name, expected in [('stop', 0), ('get_state', 0),
                                           ('get_schedule', 0), ('start', 1)]:
                await command(command_name)
                self.assertEqual(json.loads((await receive())['text']), {'state': expected})
                schedule = json.loads((await receive())['text'])['schedule']
                if expected:
                    self.assertEqual(schedule['running']['name'], 'Chess')
                else:
                    self.assertEqual(schedule['running'], {})

    async def test_unknown_profile_websocket_is_rejected(self):
        async with websocket(self.app, 'not-a-demonstration') as (receive, _):
            message = await receive()
            self.assertEqual(message['type'], 'websocket.close')
            self.assertEqual(message['code'], 1008)


if __name__ == '__main__':
    unittest.main()
