"""Bind the native stable UID selection to the actual CoreAudio stream."""
import ctypes

def open_input(sd, command, callback):
    target = command.get('coreAudioID')
    if target is None:  # Existing isolated audio fixture / command compatibility.
        device = command.get('device')
        if device is not None and device < 0: device = None
        info = sd.query_devices(device, 'input')
        rate = int(info['default_samplerate'])
        return sd.InputStream(device=device, channels=1, samplerate=rate,
            dtype='float32', blocksize=int(rate*.05), callback=callback), info, rate
    # Refresh PortAudio's device inventory only when no input stream is open.
    sd._terminate(); sd._initialize()
    candidates = [(i,d) for i,d in enumerate(sd.query_devices())
        if d['max_input_channels'] > 0 and d['name'] == command.get('deviceName')
        and sd.query_hostapis(d['hostapi'])['name'] == 'Core Audio']
    library = ctypes.CDLL(sd._libname)
    identify = library.PaMacCore_GetStreamInputDevice
    identify.argtypes = [ctypes.c_void_p]; identify.restype = ctypes.c_uint32
    for index,info in candidates:
        rate = int(info['default_samplerate'])
        stream = sd.InputStream(device=index, channels=1, samplerate=rate,
            dtype='float32', blocksize=int(rate*.05), callback=callback)
        actual = identify(int(sd._ffi.cast('uintptr_t', stream._ptr)))
        if actual == int(target): return stream, info, rate
        stream.close()
    raise RuntimeError('所选设备已变化或不可用，请刷新输入设备后继续（未启动采集）')
