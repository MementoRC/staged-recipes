import asyncio
from qemu.qmp import QMPClient

async def main():
    qmp = QMPClient('aarch64-vm')
    await qmp.connect('qmp-sock')

    print("Waiting for VM to boot...")
    while True:
        status = await qmp.execute('query-status')
        if status['status'] == 'running':
            try:
                # Check if we can execute a command in the guest
                response = await qmp.execute('guest-exec', data={
                    'path': '/bin/true',
                    'arg': [],
                    'capture-output': False
                })
                if 'pid' in response:
                    print("VM has finished booting")
                    break
                print(f"Waiting for VM to boot... (status: {status['status']} - response: {response})")
            except Exception as e:
                print(f"Error: {e}")
        await asyncio.sleep(60)

    res = await qmp.execute('system_powerdown')
    print(f"VM response: {res}")

    res = await qmp.execute('quit')
    print(f"VM response: {res}")

    await asyncio.sleep(120)
    res = await qmp.execute('query-status')
    print(f"VM status: {res['status']}")

    await qmp.disconnect()

asyncio.run(main())
