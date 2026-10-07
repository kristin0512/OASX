"""AzurTian v0.3.9 UI fixture: synthetic, in memory, loopback port 22391.

No OAS runtime, game, ADB, subprocess, or real configuration is imported/read.
The bundled data contains default argument schemas plus Chess. Edits disappear
when this process exits. Statistics are intentionally absent, like runhey OAS;
the frontend capability check must display its native empty statistics state.
"""

import asyncio
import copy
from contextlib import suppress
from datetime import datetime, timedelta
import json
from pathlib import Path

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
import uvicorn


HOST = '127.0.0.1'
PORT = 22391
DEMO_NAMES = ('演示-主号日常', '演示-百鬼棋局', '演示-每周任务')
DATA_PATH = Path(__file__).with_name('preview_data.json')


class PreviewData:
    def __init__(self):
        self.data = json.loads(DATA_PATH.read_text(encoding='utf-8'))
        self.names = list(DEMO_NAMES)
        self.states = dict(zip(self.names, [1, 1, 0]))
        self.tasks = dict(zip(self.names, ['Orochi', 'Chess', 'WeeklyTrifles']))
        self.schemas = {name: copy.deepcopy(self.data['schemas']) for name in self.names}
        self.next_runs = {}

    def require_name(self, name):
        if name not in self.schemas:
            raise HTTPException(404, 'Unknown demonstration configuration')

    def require_task(self, name, task):
        self.require_name(name)
        if task not in self.schemas[name]:
            raise HTTPException(404, 'Unknown demonstration task')
        return self.schemas[name][task]

    @staticmethod
    def validate_new_name(name):
        if not name.strip() or '演示' not in name or any(c in name for c in '/\\'):
            raise HTTPException(422, '演示配置名称必须保留“演示”字样')

    def schedule(self, name):
        now = datetime.now().replace(microsecond=0)

        def task(name_):
            next_run = self.next_runs.get((name, name_), str(now + timedelta(minutes=5)))
            return {'name': name_, 'next_run': next_run}

        return {
            'running': task(self.tasks[name]) if self.states[name] == 1 else {},
            'pending': [task('Pets'), task('TalismanPass')],
            'waiting': [task('DemonEncounter')],
        }


def create_app():
    app = FastAPI(title='AzurTian OASX 演示（离线内存数据）', version='0.3.9-preview')
    store = PreviewData()
    app.state.preview = store

    @app.get('/preview_identity')
    def identity():
        return {'kind': 'oasx-azurtian-preview', 'version': 1,
                'port': PORT, 'demo': True, 'supports_statistics': False}

    @app.get('/test')
    def test_address():
        return 'success'

    @app.get('/home/test')
    def home_test():
        return {'message': 'test'}

    @app.get('/config_list')
    def config_list():
        return store.names

    @app.get('/config_all')
    def config_all():
        return ['template', *store.names]

    @app.get('/config_new_name')
    def new_name():
        counter = 1
        while f'演示-新配置{counter}' in store.names:
            counter += 1
        return f'演示-新配置{counter}'

    @app.post('/config_copy')
    def config_copy(file: str, template: str):
        store.validate_new_name(file)
        if file in store.names:
            raise HTTPException(409, 'Demonstration configuration already exists')
        if template != 'template':
            store.require_name(template)
        store.schemas[file] = copy.deepcopy(
            store.data['schemas'] if template == 'template' else store.schemas[template])
        store.names.append(file)
        store.states[file] = 0
        store.tasks[file] = 'Chess'
        return store.names

    @app.delete('/config')
    def delete_config(name: str):
        store.require_name(name)
        store.names.remove(name)
        store.schemas.pop(name)
        store.states.pop(name)
        store.tasks.pop(name)
        return True

    @app.put('/config')
    def rename_config(old_name: str, new_name: str):
        store.require_name(old_name)
        store.validate_new_name(new_name)
        if new_name in store.names:
            raise HTTPException(409, 'Demonstration configuration already exists')
        store.names[store.names.index(old_name)] = new_name
        store.schemas[new_name] = store.schemas.pop(old_name)
        store.states[new_name] = store.states.pop(old_name)
        store.tasks[new_name] = store.tasks.pop(old_name)
        return True

    @app.put('/config/task/copy')
    def copy_task(task_name: str, dest_config_name: str, source_config_name: str):
        source = store.require_task(source_config_name, task_name)
        store.require_name(dest_config_name)
        store.schemas[dest_config_name][task_name] = copy.deepcopy(source)
        return True

    @app.put('/config/task/group/copy')
    def copy_group(task_name: str, group_name: str,
                   dest_config_name: str, source_config_name: str):
        source = store.require_task(source_config_name, task_name)
        target = store.require_task(dest_config_name, task_name)
        if group_name not in source:
            raise HTTPException(404, 'Unknown demonstration group')
        target[group_name] = copy.deepcopy(source[group_name])
        return True

    @app.get('/script_menu')
    def script_menu():
        return store.data['menu']

    @app.get('/home/home_menu')
    def home_menu():
        return {'Home': [], 'Updater': [], 'Tool': []}

    @app.get('/home/additional_translate')
    def translations():
        return store.data['translations']

    @app.put('/home/chinese_translate')
    def accept_translation():
        return True

    @app.get('/{name}/{task}/args')
    def args(name: str, task: str):
        return store.require_task(name, task)

    @app.put('/{name}/{task}/{group}/{argument}/value')
    def put_arg(name: str, task: str, group: str, argument: str, types: str, value: str):
        groups = store.require_task(name, task)
        entry = next((e for e in groups.get(group, []) if e.get('name') == argument), None)
        if entry is None:
            raise HTTPException(404, 'Unknown demonstration argument')
        if types != entry.get('type'):
            raise HTTPException(422, 'Argument type does not match schema')
        try:
            converted = value
            if types == 'boolean':
                if value.lower() not in ('true', 'false'):
                    raise ValueError('boolean must be true or false')
                converted = value.lower() == 'true'
            elif types == 'integer':
                converted = int(value)
            elif types == 'number':
                converted = float(value)
            elif types == 'enum' and value not in entry.get('enumEnum', []):
                raise ValueError('unknown enum value')
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        entry['value'] = converted
        return True

    @app.put('/{name}/{task}/sync_next_run')
    def sync_next_run(name: str, task: str, target_dt: str):
        groups = store.require_task(name, task)
        try:
            datetime.fromisoformat(target_dt)
        except ValueError as exc:
            raise HTTPException(422, 'Invalid demonstration timestamp') from exc
        store.next_runs[(name, task)] = target_dt
        for entry in groups.get('scheduler', []):
            if entry['name'] == 'next_run':
                entry['value'] = target_dt
        return True

    @app.websocket('/ws/{name}')
    async def ws(websocket: WebSocket, name: str):
        if name not in store.states:
            await websocket.close(code=1008)
            return
        await websocket.accept()

        async def update():
            await websocket.send_json({'state': store.states[name]})
            await websocket.send_json({'schedule': store.schedule(name)})

        async def demo_logs():
            messages = [
                ('INFO', '演示模式：以下日志不是游戏实机状态，操作只修改内存演示数据'),
                ('INFO', '演示：已加载主线任务菜单与百鬼棋局配置'),
                ('DEBUG', '演示：等待下一次调度检查'),
                ('WARNING', '演示：统计接口不可用，原生统计面板显示空状态'),
            ]
            count = 0
            while True:
                level, message = messages[count % len(messages)]
                await websocket.send_text(f'{level} {datetime.now():%H:%M:%S} | {message}\n')
                count += 1
                await asyncio.sleep(2)

        await update()
        log_sender = asyncio.create_task(demo_logs())
        try:
            while True:
                command = await websocket.receive_text()
                if name not in store.states:
                    break
                if command == 'start':
                    store.states[name] = 1
                elif command == 'stop':
                    store.states[name] = 0
                elif command not in ('get_state', 'get_schedule'):
                    await websocket.send_text(f'WARNING | 演示：忽略未知命令 {command}\n')
                await update()
        except WebSocketDisconnect:
            pass
        finally:
            log_sender.cancel()
            with suppress(asyncio.CancelledError, RuntimeError):
                await log_sender

    return app


app = create_app()


if __name__ == '__main__':
    uvicorn.run(app, host=HOST, port=PORT, access_log=False)
