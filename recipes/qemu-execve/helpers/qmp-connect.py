import asyncio
from qemu.qmp import QMPClient

async def main():
    qmp = QMPClient('aarch64-vm')
    await qmp.connect('qmp-sock')

    print("Waiting for VM to boot...")
    boot_completed = False
    while not boot_completed:
        try:
            status = await qmp.execute('query-status')
            if status['status'] == 'running':
                # VM is running, now let's check if it's responsive
                info = await qmp.execute('query-name')
                if info:
                    print(f"VM has finished booting. VM name: {info.get('name', 'Unknown')}")
                    boot_completed = True
            else:
                print(f"VM status: {status['status']}")
        except Exception as e:
            print(f"Error querying VM: {e}")

        if not boot_completed:
            await asyncio.sleep(60)

    await qmp.execute('system_powerdown')
    print("VM is shutting down...")
    await asyncio.sleep(60)

    res = await qmp.execute('quit')
    print(f"VM response: {res}")

    try:
        await qmp.connect('qmp-sock')
        print("Warning: VM is still running after shutdown commands")
    except Exception as e:
        print("VM has successfully shut down")

    try:
        await qmp.disconnect()
    except:
        pass

asyncio.run(main())
